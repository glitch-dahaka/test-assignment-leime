ANSIBLE := $(firstword $(wildcard .venv/bin/ansible-playbook) ansible-playbook)

export ANSIBLE_NOCOLOR := 1
export ANSIBLE_CONFIG := $(CURDIR)/ansible.cfg

.PHONY: deploy syntax verify destroy

deploy:
	$(ANSIBLE) playbooks/site.yml

syntax:
	$(ANSIBLE) playbooks/site.yml --syntax-check

verify:
	tests/verify.sh

destroy:
	$(ANSIBLE) playbooks/destroy.yml
