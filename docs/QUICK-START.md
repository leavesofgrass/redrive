# redrive quick start

redrive is a small helper on your Windows PC. While your reMarkable tablet is plugged into the
PC with its cable and awake, redrive copies your OneNote pages onto the tablet and brings the
handwriting you add on the tablet back into OneNote. Everything travels through the cable.
Nothing goes over the internet.

You set it up once, in about ten minutes. After that the routine is: plug in, tap the tablet,
unplug when you leave.

redrive is new. Until it has run on your tablet for a while, keep your own copies of any notes
you cannot afford to lose.

## What you need

- A PC with Windows 10 or 11.
- The OneNote desktop app. Click Start and type OneNote: the one you want is called just
  "OneNote" (purple icon). "OneNote for Windows 10" is a different, retired app and does not
  work with redrive.
- A reMarkable tablet and the cable that came with it. Some other cables only charge and
  cannot carry data.
- The redrive folder from the person who gave it to you (usually a file called redrive.zip).

## Part 1: on the tablet

1. **Turn on Developer mode (Paper Pro, Paper Pro Move and Paper Pure only).** Skip this step
   on a reMarkable 1 or 2.
   **Warning: this wipes the tablet back to how it came out of the box.** Everything on it is
   erased and it walks you through first-time setup again. Do this before you put anything on
   the tablet you want to keep.
   On the tablet: Settings > General > Software. Tap the version number (it looks like
   3.x.x.x and opens more options). Then Advanced > Developer mode > Accept. When the tablet
   has restarted and you have set it up again, carry on.
2. **Find the tablet's password.** The tablet has a built-in password that redrive needs once.
   Settings > General > Help > About > Copyrights and licenses. Scroll down the long legal text
   to the heading "GPLv3 Compliance". Under it is a line starting "password:" followed by a
   short jumble of letters and digits. Write it down exactly as shown. Capitals matter, and
   watch for 0 versus O and 1 versus l.
3. **Recommended: stop the tablet from sleeping while it is plugged in.** Settings > Battery,
   turn off Automatic sleep. Without this the tablet falls asleep after about 20 minutes and
   nothing syncs until you tap it. If you turn sleep off, press the power button once when you
   unplug in the evening, and turn Automatic sleep back on before a holiday.
4. **Plug in and tap.** Plug the cable into any USB socket on the PC and tap the tablet's
   screen so it is awake.

## Part 2: on the PC, the first time only

1. If you received a zip file (its name starts with redrive): right-click it, choose
   "Extract All...", then click "Extract". A folder with the same name appears next to it, with
   the file Install inside. Use that folder from now on and keep it.
2. Open the redrive folder and double-click the file called Install (it may be shown as
   Install.cmd). A plain double-click; do not choose "Run as administrator".
   If a blue box "Windows protected your PC" appears, click "More info", then "Run anyway".
   If a box "Open File - Security Warning" appears, click "Run".
   If the black window says "This window is running as administrator.", close it and
   double-click Install again from a normal window.
3. A black window appears and works through a few steps. If it says it is "Asking for
   administrator rights", a "User Account Control" box appears (it may flash on the taskbar):
   click Yes. If that box asks for an administrator's name and password, ask your IT person.
4. When it says "Plug the tablet into this PC with its USB cable and tap the screen so it is
   awake." and then "Waiting... (Ctrl+C to give up)", tap the tablet. You should see
   "tablet found at 10.11.99.1". Still waiting after a minute? Unplug both ends of the cable,
   plug them back in and tap the tablet. If that does not help, try another USB socket or
   another cable.
5. When it says "Type the tablet's password and press Enter (attempt 1 of 3).", type the
   password from Part 1 and press Enter. Nothing shows while you type; that is normal. If it
   says "That did not work", check the capitals, 0 versus O and 1 versus l, tap the tablet, and
   try again. After three failed tries, double-click Install again.
6. The window may say it is turning on the tablet's web interface. The tablet's screen goes
   blank for about ten seconds. That is expected.
7. When you see the green word "Done." press any key. The window closes. redrive now starts
   by itself every time you sign in to Windows.
8. Look next to the clock at the bottom right of the screen. A small coloured dot has
   appeared: that is redrive. (If it is hidden, click the small up-arrow next to the clock.)
   In File Explorer, under "This PC", there is now a drive usually called "reMarkable (R:)".
9. Now open OneNote. Every page of every notebook that is open in OneNote will go to the
   tablet, a batch every few minutes. A large set of notebooks can take an hour or more the
   first time. If there are notebooks you do not want on the tablet, close them in OneNote
   first: right-click the notebook's name and choose "Close This Notebook".

## The coloured dot next to the clock

Rest the mouse on the dot to read a few words about what redrive is doing. Right-click it for
the menu; the greyed-out first line of the menu shows the full message.

| Colour | What it means | What to do |
|---|---|---|
| Grey | "Waiting for the tablet (USB)" or "Tablet unplugged - R: shows the last copy" (with your drive letter) | Plug the tablet in and tap it. |
| Yellow | "Tablet asleep - tap it to wake it" | Tap the tablet's screen. |
| Blue | "Syncing..." or "Copying 3/10: ..." | Wait. |
| Green | "Up to date - last sync 09:15" | Nothing. All good. |
| Orange | "Sync problem: ..." and a bubble "Sync keeps failing - open Doctor from the redrive icon." | Open Doctor (see "If something is wrong"). |
| Red | "The tablet refused the key - run Setup again" | Plug the tablet in, tap it, and double-click Install again. Type the tablet's password once more. |

Whenever a message says "Setup", it means the Install file.

## The reMarkable drive

Open File Explorer (the yellow folder icon) and click "This PC". The drive usually called
"reMarkable (R:)" holds the tablet's folders and documents as PDF files, handwriting included.
Three rules:

1. **The copies are read-only.** The tablet is the original. Open, read and print the PDFs.
   Do not save a changed PDF over a copy. If you do, redrive treats it as a replacement: the
   changed file goes to the tablet as a new document and the old one, with its handwriting,
   moves to the tablet's Trash. A copy of the old one is kept in the drive's `_Archive`
   folder.
2. **Drop a PDF to send it.** Put a .pdf (or .epub) file into any folder of the drive. Next
   time the tablet is plugged in and awake it is sent over. The tablet shows it at the top
   level of My files first and files it into the matching folder at the next quiet moment (see
   "A normal day"). Files put in the `_Inbox` folder always go to the tablet's top level.
3. **Deleting on the PC does not delete on the tablet.** A deleted copy comes back at the
   next sync. Delete documents on the tablet itself; the copy on the PC then moves to the
   Recycle Bin.

## OneNote

Open OneNote the normal way, never as administrator. If OneNote is not running when the tablet
is plugged in, redrive starts it for you. If OneNote shows a pop-up box, close it, otherwise
nothing moves.

**What goes to the tablet.** Every page of every notebook open in OneNote, filed on the tablet
under OneNote > notebook name > section name. After the first time, only pages you changed are
sent again. Deleting a page in OneNote moves its tablet copy to the tablet's Trash. Closing a
notebook in OneNote leaves its tablet copies alone; they just stop updating.

**What comes back.** Write on one of those pages on the tablet. At the next sync your
handwriting appears at the bottom of the same OneNote page as pictures, under a small grey
line starting "redrive harvest", with the annotated PDF attached. The tablet then receives a
fresh copy of the page and the old one goes to its Trash, so the page briefly disappears and
returns on the tablet. Your writing is safe in OneNote.

**"From reMarkable".** Notebooks you create on the tablet itself show up as pages in a section
called "From reMarkable" in your first OneNote notebook. Those pages are never sent back to
the tablet; the tablet has the original.

## A normal day

**Morning.** Plug the tablet in and tap it. The dot turns blue while last night's handwriting
comes into OneNote, then green.

**During the day.** Work in OneNote as usual. Changed pages go to the tablet every few
minutes while it is plugged in and awake. Now and then redrive tidies up on the tablet
(filing documents into folders, trashing old copies). It waits for a quiet moment: at least
two minutes since you last wrote on the tablet, and never more than twice in ten minutes. The
tablet's screen goes blank for about ten seconds and the dot says "reMarkable app restarting
(about 10 s)". That is normal.

**Evening.** Wait until the dot is green (blue means give it a minute), then unplug. If
something was still waiting to go over, a bubble "... item(s) are waiting for the tablet -
plug it in and tap it to wake it." appears later. It is a reminder, not an error.

**After a tablet software update.** redrive normally reconnects by itself. If the dot turns
red, follow the Red row in the table above.

## If something is wrong

1. Right-click the dot and choose "Doctor (check everything)". A window lists checks marked
   [PASS], [WARN] or [FAIL]. Under each [WARN] or [FAIL] line is a "fix:" line telling you what
   to do.
2. The last line says "Report saved to ... and copied to the clipboard - paste it into an
   email to your helper." Open a new email to the person who gave you redrive and press
   Ctrl+V.
3. Handwriting not coming back into OneNote? On the tablet: Settings > Storage, make sure
   "USB web interface" is on. Then unplug the cable and plug it back in.
4. No dot at all? Sign out of Windows and sign in again (or restart the PC). The dot appears
   about 20 seconds after you sign in.

## Pausing and removing

- **Pause:** right-click the dot and choose "Pause syncing". Choose "Resume syncing" or
  "Sync now" to start again.
- **Stop for now:** right-click the dot and choose "Exit". It starts again next time you sign
  in.
- **Remove redrive:** open the redrive folder in File Explorer, click in the address bar at the
  top (the box showing the folder's location), type cmd and press Enter. In the black window
  type redrive.cmd uninstall and press Enter. When it says "redrive removed for this user."
  close the window. The PDF copies in the reMarkable folder stay on your PC, and nothing on the
  tablet is changed.
