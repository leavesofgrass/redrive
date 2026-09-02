# Preparing the tablet

Do these once, on the tablet, before running redrive's Install.cmd.

## 1. Turn on Developer mode (Paper Pro, Paper Pro Move, Paper Pure)

Settings > General > Software > tap the software version > Advanced > Developer mode > Accept.

**This erases everything on the tablet.** Do it before you put anything on it, or make sure
everything is backed up first. reMarkable 1 and reMarkable 2 do not need this step: they accept
SSH connections out of the box.

## 2. Find the password

Settings > General > Help > About > Copyrights and licenses. Scroll to "GPLv3 Compliance". The
password is shown there (on older software: Settings > Help > Copyright and licenses).

You type it once, during Install.cmd. redrive never stores it; after setup the tablet trusts
this PC by a key instead.

## 3. USB web interface

Install.cmd turns this on for you. If you prefer to do it yourself: Settings > Storage > enable
"USB web interface". redrive uses it to read your handwriting from documents.

## 4. Sleep

The tablet goes to sleep after about 20 minutes without use and disconnects from the PC while it
sleeps. redrive copes with that: it syncs whenever the tablet is awake and plugged in, and the tray
icon turns yellow with "tap the tablet to wake it" when it is asleep.

If the tablet lives on the cable at your desk, you can turn off Automatic sleep under
Settings > Battery so it stays reachable all day. Turn it back on if you take the tablet off
the cable for long periods.

## 5. Cable

Use the cable that came with the tablet or another data-capable USB-C cable. Some charging-only
cables do not carry data; the tray icon then stays grey ("waiting for the tablet").

## 6. After a tablet software update

The tablet gets a new identity after an update. redrive notices and reconnects on its own. If the
tray icon turns red ("run Setup again"), the update reset the key: run Install.cmd once more and
paste the password again.
