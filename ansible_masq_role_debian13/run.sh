
#!/usr/bin/env bash
set -euo pipefail
# Wrapper wie gewünscht:
# ansible-playbook -c=local --inventory=localhost, $@ -v ...
exec ansible-playbook -c=local --inventory=localhost, "$@" -v site.yml
