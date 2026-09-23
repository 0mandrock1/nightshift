#!/bin/sh
# Тестовий CC_NOTIFY: тихо гасить будь-яку нотифікацію, без execve стороннього
# бінарника. Раніше run-all.sh ставив CC_NOTIFY=/bin/true — cc-notify()
# викликає `sh "$NOTIFY" ...`, тобто /bin/true (ELF) парсився як shell-скрипт;
# спрацьовувало лише тому, що виклики обгорнуті в `|| true`.
exit 0
