# System Dashboard

A floating system monitor widget for Windows. One PowerShell 5.1 + WinForms script,
no installs, no admin rights.

## Start and stop

* Double-click `Start-Dashboard.bat`. It starts `SystemDashboard.ps1` as a hidden,
  detached process, so closing a terminal never kills the widget.
* Only one copy runs. Starting a second one restores and focuses the running copy.
* **If an old copy is still running, starting the `.bat` only shows the old copy.
  Close it with the "x" button before testing a new script.**
* "-" minimizes to the taskbar. "x" hides the dashboard and keeps the program running in the background
  (sampling, history, alerts and the taskbar mini widget continue); click the taskbar mini widget or start the
  `.bat` again to bring it back. To really quit, right-click the taskbar mini widget and choose **Exit**, or use
  **Exit dashboard** at the bottom of the settings menu. Exiting stops timers and the sampler, disposes the
  popup, releases the mutex and writes a log line. If the taskbar mini widget is off, or **Keep running in the
  background when closed (x)** is off, "x" exits completely as before.

## What it shows (sampled about every 1 s)

* **CPU** total %, 2-minute graph, per-core bars (expanded view).
* **GPU** usage from the "GPU Engine" counters (sum per engine type, max across
  types) and VRAM used when available. Shows "N/A" if there is no usable counter.
* **Memory** used / total, % used, 2-minute graph.
* **Network** download and upload speed of the busiest active adapter, 2-minute graph.
* **Disk** activity %, read and write speed, free space per fixed drive.
* Uptime and the top 3 processes by CPU and by RAM.

Compact view (about 380x200): CPU ring gauge, GPU / RAM / Disk values, and download / upload speed chips.
Expanded view (same width, about 380x832, clamped to the screen): the compact view stays exactly as it is at the top, and below it a **System | Network** switch shows either the System page - CPU/GPU and memory graphs, uptime, per-core bars, drives, top processes, and the "View history" / "Open alerts log" buttons - or the Network page (see below).

## Window

* Drag by the header or the body and drop it anywhere, on any screen. The position is remembered and the
  widget is kept inside the working area. Expanding keeps the top-left corner in place (it moves up only if
  the expanded window would not fit). Optional: **Window and power > Snap to screen corners after moving**
  makes it ease into the nearest corner (12 px margin) after every drag, as before.
* Re-snaps automatically when the screen layout changes (checked every 3 s).
* Text is DPI-aware. All sizes scale with the system DPI.

## Settings (gear button)

Background colour (six themes plus a custom colour), glass on/off and glass opacity,
alert thresholds (CPU, GPU, RAM), sustained duration, cooldown, refresh rate,
history interval, and toggles for alerts and history logging. A "Test popup" item
shows a sample toast. Everything is saved in `MonitorData\settings.json`.

## Frosted glass

The widget paints its own blurred background from a picture of the screen behind it. To avoid blurring a
picture of itself, it is excluded from screen capture (`SetWindowDisplayAffinity`) for about 50 ms during each
refresh and shown to capture tools the rest of the time, so **screenshots and recordings include the widget**.
The blur refreshes right after you move, resize or show the widget and then about every 2 s, so the
background can lag a little when windows behind it change. A screenshot taken in the split second of a refresh
(about 2% of the time) may miss the widget. If the call is not supported (older Windows), the widget logs it and
uses a solid tinted background. Nothing from the desktop ever shows through.

## Taskbar mini widget

A small widget that stays above the taskbar (CPU and RAM, coloured by load) drawn as plain text with no border and no background, so it looks like part of the taskbar. The text turns dark on a light Windows taskbar and light on a dark one, and a very faint highlight appears only while the mouse is over it sits on the taskbar, by default on the left
**between the Widgets button and the Start icon** (Windows 11). Click it to open the dashboard; click it again to
minimize the dashboard. Right-click it for **Open dashboard** and **Exit**.
Windows does not allow apps to add real items to the taskbar, so this is a tiny see-through window (per-pixel transparency) placed over it.
The positions of the Widgets and Start buttons are read with Windows UI Automation on a background thread (every 2 s),
so the widget follows them when the taskbar changes. If they cannot be found it goes to the left end of the taskbar.
Choose **Window and power > Taskbar mini widget position > Right** to put it next to the tray area (the ^ button,
wifi, sound, clock) instead. It re-raises itself every 0.5 s, hides with an auto-hidden taskbar or a fullscreen app,
and works as the way back when the dashboard is minimized, closed to the background, or click-through is on.
Turn it off in **Window and power > Taskbar mini widget**. It is placed for a horizontal taskbar (and above the tray
on a vertical one) and cannot be dragged. With many open apps, the centred app icons can grow towards it.

## Network assistant

Everything below is on the **Network** tab of the expanded view (the **System | Network** switch under the small
view), plus a chip in the small view (the network name and signal % on Wi-Fi, or "Ethernet" and the link speed on a
wired connection). It works on **Wi-Fi and on a wired Ethernet connection**: it picks the active adapter (one with an
IPv4 address and a gateway; real hardware is preferred over virtual adapters such as VMware, Hyper-V or VPN), and
follows it if you switch. It runs in the background and can be turned off in **Settings > Network assistant >
Network monitoring**.

* **Connection:** on Wi-Fi the network name, band, channel, radio type, signal % with a bar and link speed; on
  Ethernet the adapter name, link speed (for example 1 Gbps), IP address and gateway. Both show the live speed.
  If Windows blocks Wi-Fi names, turn on Windows Location.
* **Traffic graph:** the last 2 minutes of download and upload of that adapter, in Mbps.
* **Pings:** router ping and internet ping (to 1.1.1.1), coloured good / warning / bad.
* **Speed test:** uses `curl.exe` against Cloudflare, bound to the active adapter. Run it with the **Speed test**
  button or **Settings > Network assistant > Run speed test now**, or let it run every 30 minutes. A slow result is
  confirmed with a second test 20 seconds later before a **Slow internet!** popup appears (at most once per
  15 minutes). **Speed is back!** appears when it recovers, and **Good speed today** once a day. The slow-speed
  limit is 5, 10, 25 or 50 Mbps. If the server refuses the download, that is reported as "refused", never as slow.
* **DNS Shield:** checks that the PC's DNS servers are a malware / scam filtering service (Cloudflare 1.1.1.2,
  Quad9, AdGuard, CleanBrowsing, OpenDNS FamilyShield) and that they answer; it also spots a typo such as 8.8.8.4.
  It re-checks every 10 minutes. If a working shield turns OFF you get a popup with **Fix it**, which can set
  Cloudflare's scam filter on the active adapter or go back to automatic. Windows asks for administrator permission
  first; nothing changes unless you approve it.
* **Devices on your network:** found with a DHCP listener (UDP 67), the ARP table and a ping sweep of your own /24
  network. Click a device to give it a name; names are saved in `MonitorData\devices.json`. Scroll the list with the
  mouse wheel. A new or long-absent device with no name raises a popup (not during the first 45 s after start) with
  **It's mine** (opens the naming box) and **Block...** (copies its MAC address and explains how to block it in the
  router, because a PC cannot remove a device from a network). Turn these off with **Settings > Alert types > New machine connected to the network**.
* **Full test** (button on the Network page, or **Settings > Network assistant > Run full test**): takes 1-3 minutes
  and works on Wi-Fi and on Ethernet. It measures, on the active connection: 30 pings to your router and 20 each to
  Cloudflare (1.1.1.1) and Google (8.8.8.8) with minimum / average / maximum, jitter and packet loss; the DNS servers
  (does each answer, is it a scam-filtering service, typos such as 8.8.8.4) and the DNS lookup time (median of 5 real
  names); two download tests and one upload test (Cloudflare, bound to the adapter, with smaller files tried if the
  server refuses the big one); a traceroute to 1.1.1.1; and on Wi-Fi the signal, RSSI in dBm, channel, band, radio type,
  link rate and how many other networks share your channel (on a cable: the link speed instead).
  It then gives a **grade** (Excellent, Good, Fair, Poor) with a score out of 100, a **"where might the bottleneck be?"**
  answer (Wi-Fi link or router, weak signal, cable or router port, your internet provider, crowded 2.4 GHz channel, slow
  DNS, or your plan's speed), and a **diagnostics table** where every check is marked PASS, INFO or WARN with a plain
  explanation. The router's address and other private addresses are hidden in the saved report. A popup shows the result
  with a **Dashboard** button; the report is saved in `MonitorData\fulltests\` (the last 30 are kept).
* **Dashboard** (button on the Network page, or **Settings > Network assistant > Open network dashboard**): opens
  `MonitorData\network.html` in your browser, on its **Network** tab. It shows charts of Wi-Fi signal, router and
  internet ping and traffic for 1 hour to 30 days (hover for exact values), the latest full test in detail (bottleneck, diagnostics table and route trace), charts of every full test's speed and delay
  over time, every speed test, the full test history, all devices found with their names, and a list of new /
  returning devices. It is the same page as the history page, so System, Alerts and Log are one click away.
* **Saved history** (nothing is lost when the widget closes): `network-YYYY-MM.csv` (a row every few seconds: adapter,
  Wi-Fi name, signal, channel, link speed, download, upload, router ping, internet ping), `speedtests.csv`,
  `fulltests.csv`, `device-events.csv` and `devices.json`. **History cleanup** also compresses or deletes old
  `network-*` files, and **History logging** switches the network rows on or off.
* **Internet outages:** the router and internet pings (every 3 seconds) are watched. Two failed rounds in a row start an
  outage and two good rounds end it, so a single lost ping is ignored. Each outage is saved in `outages.csv` with its start,
  end, length and **cause**: *internet* (the router answers but the internet does not, so it is beyond your router),
  *router* (your router stopped answering) or *no link* (this PC lost the connection). Sleep and hibernate are not counted.
  A popup tells you when the connection is back and how long it was down (turn it off under **Alert types**). The web
  dashboard shows the timeline and table for the range you pick. If your network blocks ping, the internet check falls
  back to a normal web connection (port 443) before it calls the internet lost, and the Internet ping tile says so.
* **Data usage:** the bytes sent and received by the active connection are counted every second and stored per day in
  `usage.json` (the last 62 days). The Network page shows the total since the counter's start day, with a bar if you set
  **Settings > Network assistant > Monthly data limit**; you get a popup at 80% and at 100% (once per period, **Alert types >
  Monthly data limit**). **Data counter restarts on day** matches your billing day. It counts only this PC's traffic on the
  active adapter while the dashboard is running, so your provider's own figure can be higher. The web dashboard has a
  daily chart.
* **Report for my internet provider** (**Settings > Network assistant**, or the **Provider report** tab of the web
  dashboard): a printable page for the last 7 or 30 days with the number and length of outages by cause, estimated
  availability, speed-test results and how many were below your slow-speed limit, the share of pings without an answer,
  data used, a day-by-day table and your full tests. Use **Print / save as PDF** to keep it or send it. Only things measured
  while the dashboard was running are included.
* **The bottom panel of the Network tab** has four switches, so everything is in the app itself and not only in the
  settings menu:
  * **Devices:** the devices found on your network (click one to name it; scroll with the mouse wheel).
  * **Wi-Fi:** the networks around you (name, band, channel, signal, security; yours is marked) with the **quietest 2.4 GHz
    channel** (among 1, 6 and 11) and the **quietest 5 GHz channel**, and advice if your own channel is crowded. It scans
    when you switch to it, every 30 seconds while it stays showing, and when you press **Scan now** (no administrator
    rights needed). The last scan is also shown in the web dashboard.
  * **DNS:** the DNS Shield state, when it was last checked, and every DNS server with what it is (scam filter, your
    router, or unfiltered), whether it answers and how fast. **Check now** re-checks immediately and **Fix it / DNS
    options** opens the change dialog. The dot on the DNS switch shows the shield state while you look at another view.
  * **Speed:** the last result, when the next automatic test runs, the recent results with bars (red = below your
    slow-speed limit) and a **Run speed test now** button.
  The expanded view has two tabs, **System | Network**, and the widget remembers which view you last used.
* **Device names (guesses):** devices you have not named are labelled with a best guess such as "iPhone (guess)" or "Apple
  device - unnamed", taken from the name the device announces, its DHCP class, or the maker of its network card (a small
  built-in table). Guesses can be wrong and never replace your own names. Phones that use a private address are shown as
  "Phone or laptop (private address)".
* **Popups** all follow the dashboard rules: at most one every 10 s, the rest wait in a queue, 20 s auto-hide.
  **Settings > Network assistant > Preview network popups** shows how each one looks.

On a small screen the **System** tab scrolls with the mouse wheel (a thin scroll thumb shows at the right edge) so no panel,
such as Top processes, is ever left out; on a taller screen the panels simply grow to fill the window.

The **System** tab no longer has a network graph (it moved to the Network tab), so its CPU / GPU and memory graphs
are taller.

Notes: Windows Firewall may ask once whether PowerShell may listen on the network (that is the DHCP listener). If it
is blocked, devices are still found through ARP and the ping sweep. Private (random) MAC addresses used by modern phones
can make the same phone appear as a new device after it changes network or settings.

## Alert switches

**Settings > Alerts enabled** is the master switch. **Settings > Alert types** has one switch for each kind of alert:
high CPU usage, high GPU usage, high memory (RAM) usage, low disk space, a new machine connected to the network (Wi-Fi
or Ethernet), slow / recovered internet speed, and DNS Shield turned off. Turning a type off also removes its popups
that are still waiting in the queue. A speed test you start yourself always shows its result.
Thresholds, duration and cooldown stay under **Settings > Alert settings**.

## Window behaviour

The dashboard behaves like a normal program window: when you click another program, that program comes in front and the
dashboard goes behind it, and clicking the dashboard (or the taskbar widget) brings it forward again. If you prefer
it to stay above everything, turn on **Settings > Window and power > Always on top of other windows**. The taskbar
widget and the alert popups always stay on top, because they have to be visible. Clicking the taskbar widget brings the
dashboard forward when it is behind another program, and minimizes it when it is already the front window.

## Battery (laptops)

On a laptop the **System** tab shows a battery panel: charge, charging / plugged in / on battery, and the time left. You get a
**Low battery** popup when the charge falls to the level you choose (**Alert settings > Low battery alert at**: 10, 15, 20 or
30%) while on battery; it appears once per discharge. On a desktop PC the panel is not shown.

## Resizing the window

Move the pointer over any edge or corner of the dashboard and it turns into the usual resize arrow; drag to make the window
wider, narrower, taller or shorter, like any other program.

* **Each view remembers its own size.** The small view and the expanded view each keep their own width and height, so
  expanding and collapsing always brings you back to the size you last used in that view. In the small view the ring and
  the rows grow with the window (the smallest height is the default one; the largest is about 140 px taller). The expanded
  view can go from 360 x 400 up to the full screen.
* **Expanding and collapsing keep the top-left corner in place:** the right and bottom edges move. The change is animated
  (about a quarter of a second, easing out): the window opens like a curtain with the final look already drawn inside, so
  no blank area is ever shown. A few seconds after start-up the dashboard draws the expanded pages once in the background
  so that even the first expand is quick.
* **Nothing overflows:** when the window is too small for everything, the System and Network pages keep their normal panel
  sizes and scroll with the mouse wheel (a thin scroll thumb shows at the right edge); when it is larger, the extra space goes
  to the graphs, the process list and the bottom lists.
* **Settings > Window and power > Reset window size** goes back to the default sizes. Resizing is switched off while
  click-through is on and during the expand / collapse animation.

## High-usage popups

If CPU, GPU or RAM stays above its threshold (default 90%) for the sustained time
(default 10 s), a toast appears above the widget. Each metric has a cooldown
(default 2 minutes), at most one popup shows every 10 s (others wait in a queue),
and the first popup waits 45 s after start. Toasts auto-hide after 20 s and never
take focus. Every alert is also written to `MonitorData\alerts.csv`.

## Files (all in `MonitorData` next to the script)

| File | Content |
|---|---|
| `settings.json` | Settings (unknown or missing keys are ignored) |
| `history-YYYY-MM.csv` | One row about every 5 s: Timestamp, CpuPercent, GpuPercent, MemPercent, MemUsedGB, NetDownKBps, NetUpKBps, DiskActivityPercent, DiskReadKBps, DiskWriteKBps |
| `devices.json` | Devices found on your network and the names you gave them |
| `network-YYYY-MM.csv` | Network history: Timestamp, AdapterType, Adapter, Ssid, SignalPercent, Channel, Band, LinkSpeedMbps, DownMbps, UpMbps, RouterPingMs, InternetPingMs |
| `speedtests.csv` | Every speed test: Timestamp, Result, Mbps, Source, AdapterType, Adapter, Ssid, Bytes, Seconds |
| `fulltests.csv`, `fulltests\\*.json` | One summary line per full test, and the detailed reports |
| `device-events.csv` | New and returning devices: Timestamp, Event, Mac, Ip, Name, Hostname, Vendor |
| `network.html`, `provider-report.html` | The generated network dashboard and the report for your provider |
| `outages.csv` | Every outage: Start, End, DurationSec, Cause, AdapterType, Adapter |
| `usage.json` | Bytes downloaded and uploaded per day (last 62 days) |
| `wifi-scan.json` | The last scan of nearby Wi-Fi networks and the channel advice |
| `alerts.csv` | Timestamp, Metric, Value, Threshold, TopProcess |
| `history.html`, `alerts.html` | The generated web pages (rebuilt each time you press the buttons) |
| `widget.log` | Start, exit, errors, setting changes, alerts (rotates at 256 KB to `widget.log.old`) |

If a CSV is locked (for example open in Excel), rows are kept in memory and written
later. The widget never crashes because of it.

## History and log page

"View history" (System page of the expanded view) builds `MonitorData\history.html` in the background and opens it in your default
browser. It is a self-contained page (no internet needed) in the same colours as the widget:

* **Overview:** range buttons (1h, 6h, 24h, 7d, 30d), summary tiles (CPU, GPU, memory, network peaks, disk,
  alert count) and charts for CPU/GPU, memory, network and disk with a hover tooltip showing the average and
  the peak of each point. The 1h/6h/24h ranges use 1-minute averages, 7d/30d use coarser buckets.
* **Alerts:** the last 300 alerts from `alerts.csv`, filterable by metric.
* **Log:** the last 600 lines of `widget.log`, filterable (errors, alerts, settings) and searchable.

The page is a snapshot taken when you press the button, so press "View history" again to refresh it.

"Open alerts log" builds `MonitorData\alerts.html` the same way and opens it straight on the **Alerts** tab:
summary tiles (total, per metric, most frequent process, latest alert), an alerts-per-day chart for the last
14 days with a hover tooltip, and the full filterable table. It is the same page, so you can switch to
Overview or Log from there.
Compressed `.csv.gz` history files are read too. "Open data folder" is in the settings menu.

## More options (settings menu)

* **Window and power**
  * **Start with Windows:** when checked, the dashboard starts hidden and automatically when you sign in to
    Windows (a per-user entry in `HKCU\...\Run`, no admin needed). Unchecked, it only starts when you start it
    yourself. The check mark shows the real state, so it also follows changes made in Task Manager > Startup apps.
    If you move the folder, the entry is updated to the new location the next time the widget runs.
  * **Size:** small, normal, large or extra large (applies immediately).
  * **Auto-hide when a fullscreen app is active:** hides the widget while a game or video covers the whole
    screen and shows it again afterwards, without taking focus.
  * **Click-through:** the widget ignores the mouse. To turn it off again, start the `.bat` a second time
    (or minimize and restore the widget from the taskbar).
  * **Slow down sampling when idle:** after N minutes without keyboard or mouse input the sampler runs every
    5 s and the window stops redrawing. It returns to normal on the next input.
* **Low disk space alert:** a popup when a fixed drive has less free space than the chosen percentage
  (default 10%, repeated at most once an hour per drive). It is logged to `alerts.csv` with Metric `DISK`,
  Value = free %, Threshold = chosen %, TopProcess = drive name.
* **History cleanup:** keep history for 3, 6, 12 or 24 months (default: forever). Older monthly CSV files are
  compressed to `.csv.gz` or deleted, in the background, shortly after start and then once a day. "Clean up now"
  runs it immediately. The current month is never touched.
* **Log level:** Normal, or Quiet (only start/exit, errors and alerts) once everything is stable.

## Custom icon

Put a square `icon.png` (or `icon.ico`) in the same folder as the script to use it as the
taskbar and window icon. Without one, a small teal ring is drawn. If the taskbar still shows
the PowerShell icon, close the widget, unpin any old taskbar shortcut, and start it again.

## Troubleshooting

Send `MonitorData\widget.log`. Errors in painting, timers, mouse handlers and the
sampler are logged there with the script line number.