# nginx + certbot в Docker Compose

Плейбук кладёт на хост с Docker `docker-compose.yml` и поднимает **nginx** и **certbot**. Для каждого domain сначала пишется HTTP-конфиг, сертификат выпускается через `certbot certonly --webroot`, затем vhost меняется на TLS: HTTPS, редирект с HTTP и `robots.txt`. У domain есть список `location`, server целиком можно закрыть basic auth.

Локальный инвентарь добавляет третий сервис, ACME-сервер Pebble. В продовом его нет: certbot ходит в Let's Encrypt.

## Запуск

Нужны Docker Compose v2, `curl`, `openssl`, Python 3 и Ansible 2.17+. Пользователь должен иметь право запускать Docker. Порты **80**, **443** и **14000** должны быть свободны. Порт **18080** занят только на время `make verify`.

`.venv` и `.runtime` в репозиторий не входят. После клонирования или распаковки архива их ещё нет: Ansible ставится в каталоге проекта, стенд создаёт `make deploy`.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
make deploy
make verify
```

`make` берёт `ansible-playbook` из `.venv`. Если в `PATH` уже есть Ansible 2.17+, первые две команды не нужны.

`make deploy` читает `inventories/local`, пишет файлы в `.runtime/nginx` и поднимает nginx, certbot и Pebble. Для `demo.test`, `www.demo.test` и `secure.test` плейбук сам проходит весь сценарий: HTTP-конфиг, сертификат, TLS, редирект, `robots.txt`, locations и basic auth. Первый запуск скачивает образы.

`make verify` проверяет этот результат и запускает плейбук ещё раз. В конце строка `ok`. На время проверки скрипт поднимает на порту 18080 сервер, на который смотрит location `/api/`. Остальные пути отвечают уже после `make deploy`.

Убрать стенд:

```bash
make destroy
```

## Локальный стенд

Стенд слушает порты **80** и **443**. `demo.test`, `www.demo.test` и `secure.test` снаружи не видны, поэтому сертификат выпускает Pebble тем же webroot-запросом, что и Let's Encrypt. Браузер этот сертификат не доверит.

Имена на localhost:

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
127.0.0.1 demo.test www.demo.test secure.test
EOF
```

Без правки hosts:

```bash
curl -sk --resolve demo.test:443:127.0.0.1 https://demo.test/
curl -sk --resolve secure.test:443:127.0.0.1 https://secure.test/          # 401
curl -sk -u demo:demo-password --resolve secure.test:443:127.0.0.1 https://secure.test/
```

Пароли: `demo` / `demo-password` и `auditor` / `auditor-password`.

## Продовый запуск

Скопировать `inventories/example` в `inventories/prod`, вписать хост, domains и пароли. DNS имён должен смотреть на сервер, порт 80 снаружи должен доходить до `nginx_http_port`. В примере уже стоят `nginx_become: true` и каталог `/opt/nginx-proxy`.

Первый выпуск лучше сделать с `certbot_staging: true`. Для продового CA поставить `false`, удалить `live/<domain>` и запустить плейбук ещё раз.

```bash
ansible-vault encrypt inventories/prod/group_vars/all.yml
ansible-playbook -i inventories/prod/hosts.ini playbooks/site.yml --ask-vault-pass
```

## Куда кладутся файлы

По умолчанию `/opt/nginx-proxy`. Compose монтирует каталоги в контейнеры, образ пересобирать не нужно.

```text
nginx_deploy_dir/
  docker-compose.yml
  bin/issue-<domain>.sh          # certbot certonly --webroot
  bin/renew.sh                  # renew и nginx reload
  bin/certbot-renew-loop.sh
  nginx/nginx.conf              # копия конфига с машины Ansible
  nginx/conf.d/<domain>.conf
  nginx/history/<domain>/        # 01-http.conf и 02-https.conf
  nginx/htpasswd/<domain>
  nginx/robots/<domain>/robots.txt
  certbot/www/
  certbot/conf/                 # /etc/letsencrypt
```

## Что происходит с domain

Код в `roles/nginx_compose/tasks/domain.yml`.

1. В `conf.d` пишется сервер на порту 80: снаружи только `/.well-known/acme-challenge/`, остальное отвечает `404 certificate pending`. Копия сохраняется в `history/.../01-http.conf`. Плейбук кладёт пробный файл в webroot и проверяет, что nginx его отдал.
2. Запускается `bin/issue-<domain>.sh`. Если задан `certbot_server`, это каталог ACME (локально Pebble). Иначе при `certbot_staging: true` берётся тестовый Let's Encrypt. Уже выпущенный сертификат повторно не заказывается.
3. Файл domain заменяется на TLS. `:443` берёт `fullchain.pem` и `privkey.pem` и отдаёт locations вместе с `robots.txt`.
4. На `:80` ACME-location остаётся, всё остальное уходит в `301` на `https://$host`. Алиас вроде `www` не схлопывается в основное имя.
5. `robots.txt` и ACME при basic auth идут с `auth_basic off`.

Пока `live/<domain>/fullchain.pem` нет, выполняются шаги 1–2. Когда сертификат уже есть, плейбук только обновляет TLS-конфиг и не затирает его временным HTTP.

## nginx.conf

`nginx_main_config_src` — путь на машине, с которой запускается Ansible. Локально это `config/nginx.conf`. Пустая строка берёт запасной файл роли `roles/nginx_compose/files/nginx.conf`. В файле обязательна строка `include /etc/nginx/conf.d/*.conf;`.

Повторный прогон перезаписывает копию на хосте (`nginx_main_config_overwrite: true`).

## Locations

Список `nginx_domains`, образец в `inventories/example/group_vars/all.yml`. У location один обработчик.

Процесс на хосте из контейнера виден как `host.docker.internal` (`host-gateway`): `http://host.docker.internal:18080/`. На локальном стенде этот процесс запускает `make verify`.

## Basic auth

```yaml
basic_auth:
  enabled: true
  realm: Restricted
  users:
    - name: admin
      password: change-me
```

В nginx попадает apr1-хеш, при повторном прогоне он тот же. `auth_basic` висит на всём server, кроме ACME, `robots.txt` и location с `basic_auth: false`.

`return` в nginx срабатывает раньше проверки пароля. Для закрытого server такой location плейбук пишет через `try_files` и именованный location, чтобы сначала прошёл basic auth.

## Продление

Контейнер certbot раз в 12 часов вызывает `certbot renew --webroot` и nginx сам не перечитывает. Reload делает `bin/renew.sh`. При `nginx_install_renew_cron: true` тот же скрипт ставится в cron на 03:15.

