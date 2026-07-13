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
        $node = 'C:\Program Files\nodejs\node.exe'
        if (-not (Test-Path $node)) { return @{ ok = $false; err = 'node missing' } }
        $json = & $node (Join-Path $dir 'cursor-usage.js')
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
        $node = 'C:\Program Files\nodejs\node.exe'
        if (-not (Test-Path $node)) { return @{ ok = $false; err = 'node missing' } }
        $json = & $node (Join-Path $dir 'opencode-usage.js')
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
    Add-Panel "  the overlay redraws every 60s`n" $M
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
    $panel.Left = $wa.Right - $panel.ActualWidth - 14
    $panel.Top = $window.Top + $window.ActualHeight + 8
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
    $claude = Update-Source 'claude' ${function:Get-ClaudeUsage} $remoteDue
    $codex = Update-Source 'codex' ${function:Get-CodexUsage} $true
    $cursor = Update-Source 'cursor' ${function:Get-CursorUsage} $remoteDue
    $opencode = Update-Source 'opencode' ${function:Get-OpenCodeUsage} $true

    $body.Inlines.Clear()
    $sections = @(
        @{ name = 'CLAUDE'; data = $claude },
        @{ name = 'CODEX '; data = $codex },
        @{ name = 'CURSOR'; data = $cursor },
        @{ name = 'OPENCD'; data = $opencode }
    )
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
    $window.Left = $wa.Right - $window.ActualWidth - 14
    $window.Top = $wa.Top + 14
    # "?" button (30px hit area) sits just left of the overlay's top row
    $btnWindow.Left = $window.Left - 34
    $btnWindow.Top = $window.Top - 4
    if ($script:panelOpen) { Set-PanelPosition }
}

$window.Add_ContentRendered({ Set-Position })
$window.Add_SizeChanged({ Set-Position })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(60)
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
