# usage-overlay.ps1
# Floating click-through overlay showing Claude Code + Codex usage windows.
# Run:  powershell -WindowStyle Hidden -File usage-overlay.ps1
# Stop: powershell -File stop-overlay.ps1   (or kill the PID in usage-overlay.pid)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $dir 'usage-overlay.pid'

# Kill a previous instance if one is still alive
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid -and $oldPid -ne $PID) {
        try { Stop-Process -Id ([int]$oldPid) -Force -Confirm:$false -ErrorAction Stop } catch {}
    }
}
Set-Content -Path $pidFile -Value $PID -Encoding ascii

# node.exe for the Cursor/OpenCode helper scripts: prefer whatever is on
# PATH (nvm, scoop, winget, ...), fall back to the default installer path.
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe -and (Test-Path 'C:\Program Files\nodejs\node.exe')) {
    $nodeExe = 'C:\Program Files\nodejs\node.exe'
}

# ---------- config ----------

# Optional config.json next to the script; any key below can be overridden.
# "sections": "auto" shows only the tools with local data on this machine,
# or list them explicitly, e.g. ["claude", "codex"].
$cfg = @{
    corner         = 'top-right'   # top-right | top-left | bottom-right | bottom-left
    marginX        = 14
    marginY        = 14
    refreshSeconds = 60
    sections       = 'auto'
}
$cfgFile = Join-Path $dir 'config.json'
if (Test-Path $cfgFile) {
    try {
        $userCfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($p in $userCfg.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch {}
}
if ($cfg.corner -notin @('top-right', 'top-left', 'bottom-right', 'bottom-left')) { $cfg.corner = 'top-right' }
$cfg.refreshSeconds = [Math]::Max(15, [int]$cfg.refreshSeconds)
$cfg.marginX = [double]$cfg.marginX
$cfg.marginY = [double]$cfg.marginY

# With "auto", a section is kept only if its tool left data on this machine,
# so tools you don't use don't show up as permanent errors.
$detected = [ordered]@{
    claude   = (Test-Path "$env:USERPROFILE\.claude\.credentials.json")
    codex    = (Test-Path "$env:USERPROFILE\.codex\sessions")
    cursor   = (Test-Path "$env:APPDATA\Cursor\User\globalStorage\state.vscdb")
    opencode = (Test-Path "$env:USERPROFILE\.local\share\opencode\opencode.db")
}
if ("$($cfg.sections)" -eq 'auto') {
    $enabledSections = @($detected.Keys | Where-Object { $detected[$_] })
    # nothing detected at all: show everything, like before
    if (-not $enabledSections) { $enabledSections = @($detected.Keys) }
} else {
    $enabledSections = @($cfg.sections | ForEach-Object { "$_".ToLower() })
}

# ---------- data ----------

function Get-ClaudeUsage {
    try {
        $cred = (Get-Content "$env:USERPROFILE\.claude\.credentials.json" -Raw | ConvertFrom-Json).claudeAiOauth
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 8 -Headers @{
            Authorization    = "Bearer $($cred.accessToken)"
            'anthropic-beta' = 'oauth-2025-04-20'
        }
        $rows = @()
        $rows += [pscustomobject]@{ Label = '5h '; Pct = [double]$r.five_hour.utilization; Resets = [datetime]$r.five_hour.resets_at }
        $rows += [pscustomobject]@{ Label = 'wk '; Pct = [double]$r.seven_day.utilization; Resets = [datetime]$r.seven_day.resets_at }
        foreach ($lim in $r.limits) {
            if ($lim.kind -eq 'weekly_scoped' -and $lim.scope.model.display_name) {
                $name = $lim.scope.model.display_name.ToLower().Substring(0, [Math]::Min(3, $lim.scope.model.display_name.Length))
                $resets = if ($lim.resets_at) { [datetime]$lim.resets_at } else { $null }
                $rows += [pscustomobject]@{ Label = $name; Pct = [double]$lim.percent; Resets = $resets }
            }
        }
        return @{ ok = $true; rows = $rows }
    } catch {
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $err = switch ($status) {
            429 { 'rate limited' }
            401 { 'auth stale' }
            default { 'offline' }
        }
        return @{ ok = $false; err = $err }
    }
}

function Get-CodexUsage {
    try {
        $newest = Get-ChildItem "$env:USERPROFILE\.codex\sessions" -Recurse -File -Filter 'rollout-*.jsonl' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($f in $newest) {
            $line = Get-Content $f.FullName | Where-Object { $_ -match '"rate_limits"' } | Select-Object -Last 1
            if (-not $line) { continue }
            $rl = ($line | ConvertFrom-Json).payload.rate_limits
            if (-not $rl) { continue }
            $epoch = [DateTimeOffset]::FromUnixTimeSeconds(0)
            $rows = @()
            if ($rl.primary) {
                $rows += [pscustomobject]@{ Label = '5h '; Pct = [double]$rl.primary.used_percent; Resets = $epoch.AddSeconds($rl.primary.resets_at).LocalDateTime }
            }
            if ($rl.secondary) {
                $rows += [pscustomobject]@{ Label = 'wk '; Pct = [double]$rl.secondary.used_percent; Resets = $epoch.AddSeconds($rl.secondary.resets_at).LocalDateTime }
            }
            return @{ ok = $true; rows = $rows; asof = $f.LastWriteTime }
        }
        return @{ ok = $false; err = 'no session data' }
    } catch {
        return @{ ok = $false; err = 'read failed' }
    }
}

function Get-CursorUsage {
    try {
        if (-not $nodeExe) { return @{ ok = $false; err = 'node missing' } }
        $json = & $nodeExe (Join-Path $dir 'cursor-usage.js')
        if (-not $json) { return @{ ok = $false; err = 'no data' } }
        $j = $json | ConvertFrom-Json
        if ($j.error) { return @{ ok = $false; err = 'fetch failed' } }
        $rows = @(
            [pscustomobject]@{ Label = 'api'; Pct = [double]$j.api; Resets = [datetime]$j.resets },
            [pscustomobject]@{ Label = 'tot'; Pct = [double]$j.total; Resets = [datetime]$j.resets }
        )
        return @{ ok = $true; rows = $rows }
    } catch {
        return @{ ok = $false; err = 'read failed' }
    }
}

function Get-OpenCodeUsage {
    # OpenCode Zen has no quota API from the local key, so we show locally
    # tracked spend instead of a % bar (rendered as a plain text line).
    try {
        if (-not $nodeExe) { return @{ ok = $false; err = 'node missing' } }
        $json = & $nodeExe (Join-Path $dir 'opencode-usage.js')
        if (-not $json) { return @{ ok = $false; err = 'no data' } }
        $j = $json | ConvertFrom-Json
        if ($j.error) { return @{ ok = $false; err = 'read failed' } }
        $text = @(
            ('mo ${0:N2} spent' -f [double]$j.month),
            ('all ${0:N2} / {1:N1}M tok' -f [double]$j.total, (([double]$j.tin + [double]$j.tout) / 1e6))
        )
        return @{ ok = $true; textRows = $text }
    } catch {
        return @{ ok = $false; err = 'read failed' }
    }
}

# ---------- rendering helpers ----------

function Format-Reset($t) {
    if (-not $t) { return '--' }
    $span = $t.ToLocalTime() - (Get-Date)
    if ($span.TotalMinutes -le 0) { return 'now' }
    if ($span.TotalHours -lt 1) { return ('{0}m' -f [Math]::Ceiling($span.TotalMinutes)) }
    return ('{0}h' -f [Math]::Round($span.TotalHours))
}

function Get-Bar([double]$pct) {
    $filled = [Math]::Round([Math]::Min($pct, 100) / 10)
    return ('#' * $filled) + ('-' * (10 - $filled))
}

function Get-PctColor([double]$pct) {
    if ($pct -ge 85) { return '#FF7B72' }
    if ($pct -ge 60) { return '#E3B341' }
    return '#7EE787'
}

# ---------- window ----------

function New-XamlWindow([string]$xamlText) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
    return [Windows.Markup.XamlReader]::Load($reader)
}

$window = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        ShowActivated="False" ResizeMode="NoResize">
  <Border Background="#B40D1117" CornerRadius="6" Padding="12,9,12,9"
          BorderBrush="#28FFFFFF" BorderThickness="1">
    <TextBlock x:Name="Body" FontFamily="Consolas" FontSize="13"
               Foreground="#E6EDF3" LineHeight="19" Text="loading..."/>
  </Border>
</Window>
'@
$body = $window.FindName('Body')

# Tiny always-on-top "?" button (a separate window because the overlay is
# click-through and can't receive clicks itself).
$btnWindow = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        ShowActivated="False" ResizeMode="NoResize" Cursor="Hand">
  <!-- outer grid is a generous, near-invisible hit area so the click is easy -->
  <Grid Width="30" Height="30" Background="#01FFFFFF">
    <Border Width="20" Height="20" CornerRadius="10" Background="#B40D1117"
            BorderBrush="#40FFFFFF" BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Center">
      <TextBlock Text="?" FontFamily="Consolas" FontSize="12" Foreground="#C9D1D9"
                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </Grid>
</Window>
'@

# The info panel (hidden until the button is clicked).
$panel = New-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="Height"
        ShowActivated="False" ResizeMode="NoResize" Width="452">
  <Border Background="#F00A0D12" CornerRadius="8" Padding="16,13,16,14"
          BorderBrush="#33FFFFFF" BorderThickness="1">
    <TextBlock x:Name="PanelBody" FontFamily="Consolas" FontSize="12"
               Foreground="#C9D1D9" LineHeight="17" TextWrapping="Wrap"/>
  </Border>
</Window>
'@
$panelBody = $panel.FindName('PanelBody')

# Click-through / no-activate / no-alt-tab styling.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32Ex {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@
$GWL_EXSTYLE = -20
$WS_EX_TRANSPARENT = 0x20      # clicks pass through
$WS_EX_TOOLWINDOW  = 0x80      # hide from alt-tab
$WS_EX_LAYERED     = 0x80000
$WS_EX_NOACTIVATE  = 0x08000000 # never steal focus from the user's app

function Set-ExStyle($win, [int]$add) {
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $ex = [Win32Ex]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [Win32Ex]::SetWindowLong($hwnd, $GWL_EXSTYLE, $ex -bor $add) | Out-Null
}

$window.Add_SourceInitialized({
    Set-ExStyle $window ($WS_EX_TRANSPARENT -bor $WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
})
$btnWindow.Add_SourceInitialized({
    # clickable, so NOT transparent
    Set-ExStyle $btnWindow ($WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
})
$panel.Add_SourceInitialized({
    Set-ExStyle $panel ($WS_EX_LAYERED -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
})

function Add-Run([string]$text, [string]$color) {
    $run = New-Object System.Windows.Documents.Run($text)
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $body.Inlines.Add($run) | Out-Null
}

function Add-Panel([string]$text, [string]$color, [bool]$bold = $false) {
    $run = New-Object System.Windows.Documents.Run($text)
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($color))
    if ($bold) { $run.FontWeight = [System.Windows.FontWeights]::Bold }
    $panelBody.Inlines.Add($run) | Out-Null
}

# Build the (static) reference text once.
function Build-Panel {
    $H = '#58A6FF'; $M = '#8B949E'; $T = '#C9D1D9'
    $GREEN = '#7EE787'; $AMBER = '#E3B341'; $RED = '#FF7B72'

    Add-Panel "USAGE OVERLAY" $T $true
    Add-Panel "  quota across your coding agents`n`n" $M

    Add-Panel "COLORS`n" $H $true
    Add-Panel "  " $M; Add-Panel "green" $GREEN; Add-Panel "  under 60% used, plenty left`n" $M
    Add-Panel "  " $M; Add-Panel "amber" $AMBER; Add-Panel "  60-84%, getting tight`n" $M
    Add-Panel "  " $M; Add-Panel "red  " $RED;   Add-Panel "  85%+ , nearly capped`n" $M
    Add-Panel "  an " $M; Add-Panel "amber section name" $AMBER
    Add-Panel " = showing cached numbers, not live (see REFRESH)`n`n" $M

    Add-Panel "BAR & RESET`n" $H $true
    Add-Panel "  the ##---- bar is 10 cells, one per ~10% used`n" $M
    Add-Panel "  r 3h / r 45m / r now" $T; Add-Panel " = time until that window resets`n`n" $M

    Add-Panel "REFRESH`n" $H $true
    Add-Panel "  the overlay redraws every $($cfg.refreshSeconds)s`n" $M
    Add-Panel "  CODEX" $T; Add-Panel " every tick (local file, free)`n" $M
    Add-Panel "  CLAUDE" $T; Add-Panel " + " $M; Add-Panel "CURSOR" $T
    Add-Panel " every 3rd tick (~3 min): remote APIs,`n    throttled so they don't return HTTP 429`n" $M
    Add-Panel "  on any failure it keeps the last good value (" $M
    Add-Panel "amber" $AMBER; Add-Panel ") and`n    retries next cycle; cache is saved to disk across restarts`n`n" $M

    Add-Panel "SOURCES`n" $H $true
    Add-Panel "  CLAUDE" $T; Add-Panel "  api.anthropic.com/api/oauth/usage; OAuth token`n" $M
    Add-Panel "    from ~/.claude/.credentials.json (Claude Code refreshes it)`n" $M
    Add-Panel "    5h" $T; Add-Panel " rolling session   " $M
    Add-Panel "wk" $T; Add-Panel " 7-day all   " $M
    Add-Panel "fab" $T; Add-Panel " Fable weekly cap`n" $M
    Add-Panel "  CODEX" $T; Add-Panel "   newest ~/.codex/sessions rollout log, last`n" $M
    Add-Panel "    rate_limits event: a snapshot from your last Codex turn,`n    so it is only as fresh as your last Codex use`n" $M
    Add-Panel "    5h" $T; Add-Panel " 5-hour   " $M; Add-Panel "wk" $T; Add-Panel " weekly`n" $M
    Add-Panel "  CURSOR" $T; Add-Panel "  cursor.com/api/usage-summary via the session`n" $M
    Add-Panel "    token in Cursor's state.vscdb (no login needed)`n" $M
    Add-Panel "    api" $T; Add-Panel " named-model API usage   " $M
    Add-Panel "tot" $T; Add-Panel " total included`n" $M
    Add-Panel "  OPENCD" $T; Add-Panel "  Zen has no quota API from the local key, so`n" $M
    Add-Panel "    this shows local spend from opencode.db, not a % cap`n" $M
    Add-Panel "    mo" $T; Add-Panel " this-month `$   " $M
    Add-Panel "all" $T; Add-Panel " all-time `$ + tokens`n`n" $M

    Add-Panel "ERRORS`n" $H $true
    Add-Panel "  rate limited" $T; Add-Panel " 429, backing off   " $M
    Add-Panel "auth stale" $T; Add-Panel " 401, reopen the app`n" $M
    Add-Panel "  offline" $T; Add-Panel " no network`n`n" $M

    Add-Panel "click this panel or the ? button to close" $M
}

$script:panelOpen = $false
function Set-PanelPosition {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $panel.Left = if ($cfg.corner -like '*-left') { $wa.Left + $cfg.marginX }
                  else { $wa.Right - $panel.ActualWidth - $cfg.marginX }
    $panel.Top = if ($cfg.corner -like 'bottom-*') { $window.Top - $panel.ActualHeight - 8 }
                 else { $window.Top + $window.ActualHeight + 8 }
}
function Toggle-Panel {
    if ($script:panelOpen) {
        $panel.Hide()
        $script:panelOpen = $false
    } else {
        Set-PanelPosition
        $panel.Show()
        $panel.Topmost = $true
        $script:panelOpen = $true
    }
}
$btnWindow.Add_MouseLeftButtonDown({ Toggle-Panel })
$panel.Add_MouseLeftButtonDown({ Toggle-Panel })

$script:lastGood = @{}
$script:tick = -1

# Survive restarts: preload the last good numbers from disk, marked stale.
$cacheFile = Join-Path $dir 'usage-cache.json'
if (Test-Path $cacheFile) {
    try {
        $saved = Get-Content $cacheFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            $p.Value.stale = $true
            $script:lastGood[$p.Name] = $p.Value
        }
    } catch {}
}

# Fetch when due; otherwise (or on failure) fall back to the last good
# result, flagged stale so the UI can mark it with *.
function Update-Source([string]$key, [scriptblock]$fetch, [bool]$due) {
    if ($due -or -not $script:lastGood.ContainsKey($key)) {
        $d = & $fetch
        if ($d.ok) {
            $d.stale = $false
            $script:lastGood[$key] = $d
            return $d
        }
        if ($script:lastGood.ContainsKey($key)) {
            $c = $script:lastGood[$key]
            $c.stale = $true
            return $c
        }
        return $d
    }
    return $script:lastGood[$key]
}

function Render {
    $script:tick++
    # Codex is a local file read: every tick. Claude and Cursor hit remote
    # APIs that rate-limit: every 3rd tick (3 min).
    $remoteDue = ($script:tick % 3 -eq 0)
    $specs = @(
        @{ key = 'claude';   name = 'CLAUDE'; fetch = ${function:Get-ClaudeUsage};   due = $remoteDue },
        @{ key = 'codex';    name = 'CODEX '; fetch = ${function:Get-CodexUsage};    due = $true },
        @{ key = 'cursor';   name = 'CURSOR'; fetch = ${function:Get-CursorUsage};   due = $remoteDue },
        @{ key = 'opencode'; name = 'OPENCD'; fetch = ${function:Get-OpenCodeUsage}; due = $true }
    )

    $body.Inlines.Clear()
    $sections = @()
    foreach ($spec in $specs) {
        if ($enabledSections -contains $spec.key) {
            $sections += @{ name = $spec.name; data = (Update-Source $spec.key $spec.fetch $spec.due) }
        }
    }
    $first = $true
    $anyStale = $false
    foreach ($s in $sections) {
        if (-not $first) { Add-Run "`n" '#E6EDF3' }
        $first = $false
        if (-not $s.data.ok) {
            Add-Run ("{0}  {1}" -f $s.name, $s.data.err) '#8B949E'
            continue
        }
        $nameColor = '#8B949E'
        if ($s.data.stale) { $nameColor = '#E3B341'; $anyStale = $true }
        # Text-only sections (e.g. OpenCode spend): no bar/% columns.
        if ($s.data.textRows) {
            $rowIdx = 0
            foreach ($t in $s.data.textRows) {
                $prefix = if ($rowIdx -eq 0) { $s.name } else { '      ' }
                Add-Run ("{0} " -f $prefix) $nameColor
                Add-Run $t '#C9D1D9'
                if ($rowIdx -lt $s.data.textRows.Count - 1) { Add-Run "`n" '#E6EDF3' }
                $rowIdx++
            }
            continue
        }
        $rowIdx = 0
        foreach ($row in $s.data.rows) {
            $prefix = if ($rowIdx -eq 0) { $s.name } else { '      ' }
            Add-Run ("{0} " -f $prefix) $nameColor
            Add-Run ($row.Label + ' ') '#8B949E'
            Add-Run (Get-Bar $row.Pct) (Get-PctColor $row.Pct)
            Add-Run (" {0,3:N0}% " -f $row.Pct) (Get-PctColor $row.Pct)
            Add-Run ("r " + (Format-Reset $row.Resets)) '#8B949E'
            if ($rowIdx -lt $s.data.rows.Count - 1) { Add-Run "`n" '#E6EDF3' }
            $rowIdx++
        }
    }
    Add-Run ("`n" + (Get-Date -Format 'HH:mm') + ' refreshed') '#484F58'
    if ($anyStale) { Add-Run ' / amber = cached' '#E3B341' }

    try { $script:lastGood | ConvertTo-Json -Depth 6 | Set-Content -Path $cacheFile -Encoding utf8 } catch {}
}

function Set-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = if ($cfg.corner -like '*-left') { $wa.Left + $cfg.marginX }
                   else { $wa.Right - $window.ActualWidth - $cfg.marginX }
    $window.Top = if ($cfg.corner -like 'bottom-*') { $wa.Bottom - $window.ActualHeight - $cfg.marginY }
                  else { $wa.Top + $cfg.marginY }
    # "?" button (30px hit area) sits beside the overlay's top row, on the
    # side that faces the middle of the screen
    $btnWindow.Left = if ($cfg.corner -like '*-left') { $window.Left + $window.ActualWidth + 4 }
                      else { $window.Left - 34 }
    $btnWindow.Top = $window.Top - 4
    if ($script:panelOpen) { Set-PanelPosition }
}

$window.Add_ContentRendered({ Set-Position })
$window.Add_SizeChanged({ Set-Position })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($cfg.refreshSeconds)
$timer.Add_Tick({ try { Render } catch {} })

$window.Add_Loaded({
    try { Render } catch {}
    $timer.Start()
})

Build-Panel

$window.Show()
$btnWindow.Show()
$panel.Show(); $panel.Hide()   # realize handle + ex-style, then keep hidden
Set-Position

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$window.Add_Closed({ $app.Shutdown() })
$app.Run() | Out-Null
Remove-Item $pidFile -ErrorAction SilentlyContinue
