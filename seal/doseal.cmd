@echo off
rem ============================================================================
rem  doseal.cmd - strip build tooling, THEN sysprep. One atomic step.
rem
rem  WHY THIS EXISTS
rem    Clean-Scripts.ps1 deletes the seal tooling, but C3-C7 need it back, so the
rem    runbook restores it from C:\sealkit right after the clean. Nothing removed
rem    it again before sysprep - so Seal-Manual.ps1 shipped INSIDE the sealed
rem    2026-08-12 images (454 files instead of ~400). Deleting here closes the
rem    window: the tooling exists right up to the moment sysprep starts.
rem
rem  Unattend-Seal.xml is NOT deleted - sysprep reads it seconds later, and
rem  sysprep copies it to C:\Windows\Panther itself.
rem ============================================================================
setlocal
rem ---------------------------------------------------------------------------
rem RE-EXEC FROM %TEMP% FIRST.
rem cmd.exe re-reads a batch file from disk after every command. The old version
rem scheduled "del doseal.cmd" 30 seconds out and then ran sysprep, which takes
rem minutes - so the file vanished while cmd still had more of it to read and the
rem seal ended with "The batch file cannot be found." Sysprep had already run and
rem SUCCEEDED, but the message reads like a failure. Copy ourselves to %TEMP%, run
rem from there, and delete the C:\Scripts copy immediately - no race at all.
rem ---------------------------------------------------------------------------
if /i not "%~dp0"=="%TEMP%\" (
  copy /y "%~f0" "%TEMP%\yc-doseal.cmd" >nul
  del /f /q "%~f0" 2>nul
  call "%TEMP%\yc-doseal.cmd"
  exit /b %ERRORLEVEL%
)

echo [doseal] removing build/seal tooling from C:\Scripts
del /f /q "C:\Scripts\Seal-Manual.ps1"       2>nul
del /f /q "C:\Scripts\Fix-PreSeal.ps1"       2>nul
del /f /q "C:\Scripts\AppX-Strip.ps1"        2>nul
del /f /q "C:\Scripts\Install-YcTasks.ps1"   2>nul
del /f /q "C:\Scripts\Clean-Scripts.ps1"     2>nul
del /f /q "C:\Scripts\PreSeal-Agents.ps1"    2>nul
del /f /q "C:\Scripts\Enable-VirtioBoot.ps1" 2>nul
del /f /q "C:\Scripts\Fix-DiagTools.ps1"     2>nul
del /f /q "C:\Scripts\Install-YcPayload.ps1" 2>nul
del /f /q "C:\Scripts\GoldenImage*.ps1"      2>nul
del /f /q "C:\Scripts\yc-check.ps1"          2>nul
del /f /q "C:\Scripts\yc-folders.ps1"        2>nul
del /f /q "C:\Scripts\yc-id.ps1"             2>nul
del /f /q "C:\Scripts\ycpayload-v*.zip"      2>nul
del /f /q "C:\Scripts\ycpayload-v*.zip.sha256" 2>nul
del /f /q "C:\Scripts\*.log"                 2>nul
del /f /q "C:\Scripts\clean-discarded.txt"   2>nul
del /f /q "C:\Scripts\virtio-win.iso"        2>nul
rmdir /s /q "C:\sealkit"                     2>nul
rmdir /s /q "C:\Scripts\.done"               2>nul
rmdir /s /q "C:\Scripts\_stage"              2>nul

rem Delete this file too. A running .cmd cannot delete itself inline - the handle is
rem open - so a detached cmd waits 30s and removes it while sysprep is generalizing.
rem Without this, doseal.cmd was the ONE item still shipping inside the 2026-08-12
rem sealed images.
rem (the delayed self-delete lived here; the re-exec above replaces it)

rem 2026-08-30: .rearm-done is a DOT-file, so the *.log wildcard above never removed it.
rem It shipped inside every sealed image, and every VM from that template then SKIPPED the
rem first-boot rearm it was built to perform. Delete it here.
del /f /q "C:\Scripts\.rearm-done"      2>nul
rem The autoupdate STATE is a conversation with GitHub - an ETag and the hash it stood for. It is
rem per-MACHINE, and sealing it into the template hands one build VM's conversation to every clone
rem that will ever come off this image. .payload-sha256 is deliberately NOT removed: that is the
rem honest record of which payload is baked in, and the updater compares against it.
del /f /q "C:\Scripts\.autoupdate-state"     2>nul
del /f /q "C:\Scripts\.autoupdate-lastcheck" 2>nul
rem YCSEAL is created by the seal POA and was never unregistered - it shipped in the image
rem pointing at a doseal.cmd this script deletes.
schtasks /delete /tn YCSEAL /f            2>nul
rem YC-Health-Chkdsk / -Session / -SQL all point at Setup-HealthMonitors.ps1, which the
rem v265 audit deleted. They were baked into every image and failed on every clone
rem forever. Install-YcTasks retires them, but Install-YcTasks does not run in the
rem RESEAL path - only this file is guaranteed to run - so they are removed here too.
rem yc-health.ps1 already covers what they were meant to do.
schtasks /delete /tn YC-Health-Chkdsk /f  2>nul
schtasks /delete /tn YC-Health-Session /f 2>nul
schtasks /delete /tn YC-Health-SQL /f     2>nul
rem GIBuild points at GoldenImage.ps1, which is build tooling and is deliberately not
rem in C:\Scripts at seal time. Found by the new orphan-task check on 2026-08-31 - it
rem had been shipping in every image too.
schtasks /delete /tn GIBuild /f           2>nul

echo [doseal] launching sysprep
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:C:\Scripts\Unattend-Seal.xml
