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
start "" /b cmd /c "ping -n 31 127.0.0.1 >nul & del /f /q C:\Scripts\doseal.cmd"

rem 2026-08-30: .rearm-done is a DOT-file, so the *.log wildcard above never removed it.
rem It shipped inside every sealed image, and every VM from that template then SKIPPED the
rem first-boot rearm it was built to perform. Delete it here.
del /f /q "C:\Scripts\.rearm-done"      2>nul
rem YCSEAL is created by the seal POA and was never unregistered - it shipped in the image
rem pointing at a doseal.cmd this script deletes.
schtasks /delete /tn YCSEAL /f            2>nul

echo [doseal] launching sysprep
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:C:\Scripts\Unattend-Seal.xml
