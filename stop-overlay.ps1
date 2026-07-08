$pidFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'usage-overlay.pid'
if (Test-Path $pidFile) {
    $p = Get-Content $pidFile
    try { Stop-Process -Id ([int]$p) -Force -Confirm:$false } catch {}
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    "overlay stopped (pid $p)"
} else {
    "no overlay running"
}
