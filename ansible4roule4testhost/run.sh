
#!/usr/bin/env bash
set -euo pipefail
# Wrapper entsprechend:
# ansible-playbook -c=local --inventory=localhost, $@ -v ...
exec ansible-playbook -c=local --inventory=localhost, "$@" -v testhost.yml