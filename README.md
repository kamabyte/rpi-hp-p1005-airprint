# 🖨️ AirPrint-сервер для HP LaserJet P1005 на Raspberry Pi

![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Zero%202%20W-C51A4A?logo=raspberrypi&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu%20Server-22.04-E95420?logo=ubuntu&logoColor=white)
![AirPrint](https://img.shields.io/badge/AirPrint-iPhone%20%C2%B7%20iPad%20%C2%B7%20Mac-000000?logo=apple&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

## 🏆 Легенда, которая отказывается уходить на пенсию

**HP LaserJet P1005** — это легенда. Компактный, неприхотливый и почти
неубиваемый, он десятилетиями печатает в офисах, школах и домах, пережив
не одно поколение компьютеров. Картриджи для него продаются на каждом углу,
а на одной заправке он выдаёт сотни страниц. Нет Wi-Fi, нет AirPrint, нет
даже собственной прошивки во флеше — и при этом он продолжает работать там,
где более «умные» принтеры давно отправились на свалку. 💪

Этот проект возвращает легенду в строй: недорогой Raspberry Pi становится
сетевым AirPrint-мостом, и P1005 появляется в стандартном диалоге печати
на 📱 iPhone, iPad и 💻 Mac — без драйверов, приложений и проводов
к каждому устройству.

## ✨ Возможности

- 🔌 **Настройка с нуля** — от свежей карты памяти до первой страницы двумя
  скриптами.
- 🧩 **Автозагрузка прошивки** при каждом включении принтера через udev.
- 🍏 **AirPrint из коробки** — принтер находится через Bonjour автоматически.
- 🛡️ **Самовосстановление** — сторож перезапускает CUPS, если тот перестал
  отвечать.
- ⚡ **Оптимизация под Pi Zero** — разумное разрешение, без задержек USB
  и ложного дуплекса.
- 🔁 **Идемпотентность** — скрипты можно безопасно запускать повторно.

## 🧰 Оборудование и ПО

Решение проверено на следующей конфигурации:

| Компонент | Модель |
|---|---|
| 🍓 Одноплатный компьютер | Raspberry Pi Zero 2 W / WH |
| 🐧 Операционная система | Ubuntu Server 22.04, 32-бит (`armhf`) |
| 🌐 Сеть | Ethernet HAT (USB Ethernet на Realtek RTL8152, интерфейс `enx…`) |
| 🖨️ Принтер | HP LaserJet P1005, подключённый к Pi по USB |

> 🆘 Если печать перестала работать, начните с [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 📦 Состав

| Файл | Назначение |
|---|---|
| [`prepare-host.sh`](prepare-host.sh) | Подготовка системы: уникальное имя хоста, которое переживает перезагрузку, и настройка Ethernet HAT через netplan. |
| [`install-airprint-p1005.sh`](install-airprint-p1005.sh) | Установка CUPS, Avahi и драйвера `foo2zjs`, загрузка прошивки принтера, создание общей очереди, сторож для CUPS. |

Оба скрипта можно запускать повторно: уже сделанные шаги они распознают
и не дублируют.

## 🚀 Быстрый старт

1. Запишите Ubuntu Server 22.04 на карту через Raspberry Pi Imager, включите SSH
   и (по желанию) Wi-Fi как запасной канал.
2. Подключите Ethernet HAT к роутеру, а принтер — к USB-порту Pi.
3. Скопируйте репозиторий на Pi и выполните:

```bash
git clone https://github.com/kamabyte/rpi-hp-p1005-airprint.git
cd rpi-hp-p1005-airprint

# 1. Имя хоста и Ethernet. Скрипт выведет MAC-адрес Ethernet-интерфейса.
sudo NEW_HOSTNAME=printserver-hp ./prepare-host.sh

# 2. AirPrint. Имя интерфейса посмотрите командой: ls /sys/class/net
sudo AVAHI_INTERFACE=enx001122334455 PRINTER_LOCATION='Кабинет' ./install-airprint-p1005.sh
```

4. Закрепите IP за **MAC-адресом Ethernet-интерфейса** (не Wi-Fi) в DHCP-резервации
   на роутере.
5. Распечатайте тестовую страницу:

```bash
lp -d HP-LaserJet-P1005 /usr/share/cups/data/testprint
```

## 🤔 Почему P1005 требует особого подхода

P1005 — «хостовый» принтер (GDI / ZjStream):

- **только USB**, сетевого режима нет;
- **растеризация целиком на Pi** через открытый драйвер `foo2zjs` (`foo2xqx`);
  для Pi Zero это ощутимая нагрузка;
- **прошивки во флеше нет**: её нужно загружать в принтер **после каждого
  включения**. Без прошивки принтер каждые несколько секунд переподключается
  по USB, а CUPS пишет `Printer not connected; will retry`. Если задание
  «выполнено», а лист не вышел, почти всегда виновата прошивка.

## 🏷️ Что делает `prepare-host.sh`

1. Пишет `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` с
   `preserve_hostname: true`. Без этого cloud-init при каждой загрузке
   возвращает старое имя хоста.
2. Меняет имя хоста (`hostnamectl`, строка `127.0.1.1` в `/etc/hosts`), удаляет
   TLS-сертификат CUPS для старого имени и перезапускает `cups` и `avahi-daemon`.
3. Создаёт `/etc/netplan/99-ethernet.yaml` для первого найденного интерфейса
   `enx*`/`eth*`: DHCP, `route-metric: 100`. Ethernet становится основным
   маршрутом, Wi-Fi остаётся запасным для SSH. Стандартный netplan от cloud-init
   знает только `eth0`, поэтому без этого шага HAT остаётся выключенным.

Запускайте его **до** установки AirPrint: CUPS выпускает самоподписанный
сертификат на текущее имя хоста.

| Переменная | По умолчанию | Описание |
|---|---|---|
| `NEW_HOSTNAME` | `printserver-hp` | Новое имя хоста. У каждого AirPrint-сервера в сети оно должно быть своим. |
| `ETH_INTERFACE` | `auto` | Интерфейс Ethernet HAT. `none` — не трогать сеть. |

## ⚙️ Что делает `install-airprint-p1005.sh`

1. Ставит `cups`, `cups-filters`, `avahi-daemon`, `printer-driver-foo2zjs` и PPD.
2. Скачивает прошивку в `/lib/firmware/hp/sihpP1005.dl` (через `getweb P1005`
   или из `P1005_FIRMWARE`).
3. Ставит собственный загрузчик прошивки: `/usr/local/bin/p1005-loadfw.sh`
   и udev-правило `/etc/udev/rules.d/99-p1005-firmware.rules`. Штатное правило
   пакета вызывает программу `hpljP1005`, которой в Ubuntu 22.04 `armhf` нет,
   поэтому без нашего правила прошивка после включения принтера не загружается.
4. Добавляет USB-quirk `unidir` для `03f0:3d17` — убирает 7-секундную паузу
   в конце каждого задания.
5. Открывает CUPS для локальной сети и включает общий доступ к принтерам;
   если `ufw` активен, открывает `631/tcp` и `5353/udp`.
6. При заданном `AVAHI_INTERFACE` ограничивает Bonjour одним интерфейсом
   и только IPv4.
7. Находит USB-URI и драйвер `foo2xqx`, создаёт общую очередь
   `HP-LaserJet-P1005` и делает её очередью по умолчанию.
8. Задаёт практичные настройки: `600x600dpi`, `A4`, без дуплекса — и убирает
   дуплекс из AirPrint-анонса.
9. Включает `cups-watchdog.timer`: раз в минуту проверяет, что CUPS отвечает,
   и перезапускает его, если нет.
10. Проверяет итоговое состояние и печатает сводку.

Скрипт откажется перенастраивать CUPS, пока в очереди есть активные задания,
если не задать `ALLOW_ACTIVE_JOBS=1`.

### 🎛️ Переменные

| Переменная | По умолчанию | Описание |
|---|---|---|
| `QUEUE_NAME` | `HP-LaserJet-P1005` | Внутреннее имя очереди CUPS. |
| `PRINTER_NAME` | `HP LaserJet P1005` | Отображаемое имя. |
| `PRINTER_LOCATION` | — | Расположение (комната). Если не задано, скрипт спросит в терминале. |
| `PRINTER_URI` | `auto` | URI устройства, например `usb://HP/LaserJet%20P1005`. |
| `PRINTER_MODEL` / `PRINTER_PPD` | `auto` | Явная модель из `lpinfo -m` или путь к PPD. |
| `P1005_FIRMWARE` | — | Путь или URL к готовому `sihpP1005.dl`. |
| `AVAHI_INTERFACE` | — | Интерфейс для Bonjour-анонса (например, `enx…`). |
| `DEFAULT_RESOLUTION` | `600x600dpi` | Разрешение; `1200x600dpi` заметно медленнее. |
| `DEFAULT_DENSITY` | `Density5` | Плотность тонера. |
| `DEFAULT_PAGE_SIZE` | `A4` | Формат бумаги. |
| `DEFAULT_DUPLEX` | `None` | Двусторонняя печать (у P1005 нет дуплекса). |
| `DISABLE_DUPLEX_ADVERTISEMENT` | `1` | `0` — оставить варианты дуплекса в PPD. |
| `ALLOW_ACTIVE_JOBS` | `0` | `1` — перенастраивать, даже если идёт печать. |

### 📥 Если `getweb` не может скачать прошивку

`getweb` качает с `foo2zjs.com`, который иногда недоступен. Передайте файл сами:

```bash
sudo P1005_FIRMWARE=/path/to/sihpP1005.dl ./install-airprint-p1005.sh
sudo P1005_FIRMWARE='https://example.com/sihpP1005.dl' ./install-airprint-p1005.sh
```

Файл прошивки несвободный, поэтому в репозиторий он не входит.

## 🍏 Подключение с Mac

Добавляйте принтер как AirPrint / IPP, а не как `Generic PostScript Printer`:
P1005 не понимает PostScript, и в этом режиме Pi приходится делать лишнюю
работу в Ghostscript.

Если окно «Добавить принтер» на macOS выдаёт *«Unable to connect … due to
an error»*, хотя принтер виден, добавьте очередь через обычный `ipp://`
(без TLS) с драйвером IPP Everywhere:

```bash
lpadmin -p HP_LaserJet_P1005 \
  -v ipp://printserver-hp.local:631/printers/HP-LaserJet-P1005 \
  -m everywhere -o printer-is-shared=false -E
```

Плюс этого способа: растеризацию делает Mac, а Pi только передаёт готовый
растр в `foo2zjs`. Подробнее — в [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## ✅ Проверка

```bash
lpstat -t                                   # очередь общая и свободна
lpinfo -v | grep -i usb                     # USB-URI найден
lpinfo -m | grep -i p1005                   # драйвер foo2xqx на месте
ls -l /lib/firmware/hp/sihpP1005.dl         # прошивка есть
journalctl -t p1005-loadfw                  # прошивка загружалась при включении
avahi-browse -rt _ipp._tcp                  # AirPrint-анонс ровно один
systemctl status cups-watchdog.timer        # сторож CUPS включён
```

> 🐢 Pi Zero растеризует каждую страницу сам, поэтому сетевой лазерник он не
> заменит: страница текста печатается за секунды, а большая фотография может
> обрабатываться минутами. Как с этим быть — в [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 📄 Лицензия

Проект распространяется по лицензии [MIT](LICENSE). Прошивка `sihpP1005.dl`
принадлежит HP, не входит в репозиторий и скачивается отдельно.

---

<p align="center">Сделано с ❤️ для тех, кто не выбрасывает хорошую технику 🖨️</p>
