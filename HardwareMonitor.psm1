# $HOME\Documents\PowerShell\Modules\HardwareMonitor\HardwareMonitor.psm1

$script:HardwareOverlayPipeName = "HardwareMonitorOverlay-$env:USERNAME"
$script:HardwareOverlayStatePath = Join-Path $env:LOCALAPPDATA "HardwareMonitorOverlay\state.json"
$script:HardwareOverlayPidPath = Join-Path $env:LOCALAPPDATA "HardwareMonitorOverlay\overlay.pid"

$script:Monitor = @{
    Url = "http://localhost:8085/data.json"

    Flatten = {
        param($Node)

        if ($null -eq $Node) { return }

        if ($Node.Text -or $Node.Value) {
            $Node
        }

        foreach ($child in @($Node.Children)) {
            & $script:Monitor.Flatten $child
        }
    }

    GetValueByUnit = {
        param(
            [object[]]$Items,
            [string]$Pattern,
            [string]$UnitPattern
            )

        ($Items |
            Where-Object { $_.Text -match $Pattern -and $_.Value -match $UnitPattern } |
            Select-Object -First 1).Value
    }

    Num = {
        param($Value)

        if ($null -eq $Value) { return $null }
        [double](($Value -replace '[^\d\.-]', ''))
    }

    ToGB = {
        param($Value)

        if ($null -eq $Value) { return $null }

        $s = [string]$Value
        $n = [double]($s -replace '[^\d\.-]', '')

        if ($s -match 'KB') { return $n / 1MB }
        if ($s -match 'MB') { return $n / 1024 }
        if ($s -match 'GB') { return $n }

        return $n
    }

    ColorUsage = {
        param($Value)

        if ($null -eq $Value) { 'Gray' }
        elseif ($Value -ge 90) { 'Red' }
        elseif ($Value -ge 70) { 'Yellow' }
        elseif ($Value -ge 20) { 'Green' }
        else { 'Gray' }
    }

    ColorTemp = {
        param($Value)

        if ($null -eq $Value) { 'Gray' }
        elseif ($Value -ge 85) { 'Red' }
        elseif ($Value -ge 75) { 'Yellow' }
        elseif ($Value -ge 50) { 'Green' }
        else { 'Gray' }
    }

    SafePercent = {
        param($Value)

        if ($null -eq $Value) { return " --%" }
        "{0,3}%" -f [int]$Value
    }

    SafeTemp = {
        param($Value)

        if ($null -eq $Value) { return "--" }
        "{0}C" -f [int]$Value
    }

    GetSnapshot = {
        param([string]$Url = $script:Monitor.Url)

        $data = Invoke-RestMethod $Url -TimeoutSec 2
        $items = @(& $script:Monitor.Flatten $data)

        $gpu       = & $script:Monitor.Num  (& $script:Monitor.GetValueByUnit $items '^GPU Core$|^D3D 3D$' '%')
        $gpuTemp   = & $script:Monitor.Num  (& $script:Monitor.GetValueByUnit $items '^GPU Core$' '°C|C')
        $vram      = & $script:Monitor.ToGB (& $script:Monitor.GetValueByUnit $items '^GPU Memory Used$' 'MB|GB')
        $vramTotal = & $script:Monitor.ToGB (& $script:Monitor.GetValueByUnit $items '^GPU Memory Total$' 'MB|GB')
        $shared    = & $script:Monitor.ToGB (& $script:Monitor.GetValueByUnit $items '^D3D Shared Memory Used$' 'MB|GB')

        $cpu       = & $script:Monitor.Num  (& $script:Monitor.GetValueByUnit $items '^CPU Total$|^Total CPU Utility$|^CPU Package$' '%')
        $cpuTemp   = & $script:Monitor.Num  (& $script:Monitor.GetValueByUnit $items 'CPU Package|Tctl/Tdie|Core Max|CCD' '°C|C')
        $ram       = & $script:Monitor.Num  (& $script:Monitor.GetValueByUnit $items '^Memory$' '%')

        $vramPct = if ($vram -and $vramTotal) { ($vram / $vramTotal) * 100 } else { 0 }
        $badShared = ($shared -gt 1) -or (($vramPct -gt 95) -and ($shared -gt 0.01))
        $vramText = if ($null -eq $vram) { "--" } else { "{0:N2}GB" -f $vram }

        if ($badShared) {
            $vramText += "+{0:N2}GB" -f $shared
        }

        [pscustomobject]@{
            GPU        = & $script:Monitor.SafePercent $gpu
            GPUColor   = & $script:Monitor.ColorUsage $gpu
            VRAM       = $vramText
            VRAMColor  = if ($badShared) { 'Red' } else { 'Gray' }
            GTEMP      = & $script:Monitor.SafeTemp $gpuTemp
            GTEMPColor = & $script:Monitor.ColorTemp $gpuTemp
            CPU        = & $script:Monitor.SafePercent $cpu
            CPUColor   = & $script:Monitor.ColorUsage $cpu
            CTEMP      = & $script:Monitor.SafeTemp $cpuTemp
            CTEMPColor = & $script:Monitor.ColorTemp $cpuTemp
            RAM        = & $script:Monitor.SafePercent $ram
            RAMColor   = & $script:Monitor.ColorUsage $ram
        }
    }

    Layout = {
        param([pscustomobject]$Snapshot)

        @(
            [pscustomobject]@{ Title = 'GPU';  Value = $Snapshot.GPU;   Width = 6;  Color = $Snapshot.GPUColor }
            [pscustomobject]@{ Title = 'VRAM'; Value = $Snapshot.VRAM;  Width = 16; Color = $Snapshot.VRAMColor }
            [pscustomobject]@{ Title = 'GT';   Value = $Snapshot.GTEMP; Width = 5;  Color = $Snapshot.GTEMPColor }
            [pscustomobject]@{ Title = 'CPU';  Value = $Snapshot.CPU;   Width = 6;  Color = $Snapshot.CPUColor }
            [pscustomobject]@{ Title = 'CT';   Value = $Snapshot.CTEMP; Width = 5;  Color = $Snapshot.CTEMPColor }
            [pscustomobject]@{ Title = 'RAM';  Value = $Snapshot.RAM;   Width = 6;  Color = $Snapshot.RAMColor }
            )
    }

    WriteCell = {
        param(
            [string]$Text,
            [int]$Width,
            [string]$Color = 'Gray',
            [switch]$PadValue
            )

        if ($null -eq $Text) { $Text = "" }
        if ($PadValue) { $Text = " $Text " }
        if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }

        $remaining = $Width - $Text.Length
        $left = [math]::Floor($remaining / 2)
        $right = $remaining - $left
        $out = (" " * $left) + $Text + (" " * $right)

        Write-Host $out -ForegroundColor $Color -NoNewline
        $script:MonitorWritten += $out.Length
    }

    RenderConsoleRows = {
        param([object[]]$Cells)

        $top = [Console]::CursorTop
        $width = [Console]::WindowWidth

        [Console]::SetCursorPosition(0, $top)
        $script:MonitorWritten = 0

        foreach ($cell in $Cells) {
            & $script:Monitor.WriteCell $cell.Title $cell.Width 'DarkGray'
        }

        Write-Host (" " * [Math]::Max(0, $width - $script:MonitorWritten - 1)) -NoNewline

        [Console]::SetCursorPosition(0, $top + 1)
        $script:MonitorWritten = 0

        foreach ($cell in $Cells) {
            & $script:Monitor.WriteCell $cell.Value $cell.Width $cell.Color -PadValue
        }

        Write-Host (" " * [Math]::Max(0, $width - $script:MonitorWritten - 1)) -NoNewline
        [Console]::SetCursorPosition(0, $top)
    }
}

function Get-HardwareOverlayState {
    param(
        [int]$DefaultLeft = 20,
        [int]$DefaultTop = 20,
        [int]$DefaultLabelFontSize = 11,
        [int]$DefaultValueFontSize = 13
        )

    $state = [ordered]@{
        Left = $DefaultLeft
        Top = $DefaultTop
        LabelFontSize = $DefaultLabelFontSize
        ValueFontSize = $DefaultValueFontSize
    }

    if (Test-Path $script:HardwareOverlayStatePath) {
        try {
            $loaded = Get-Content $script:HardwareOverlayStatePath -Raw | ConvertFrom-Json

            foreach ($key in @('Left', 'Top', 'LabelFontSize', 'ValueFontSize')) {
                if ($null -ne $loaded.$key) {
                    $state[$key] = [int]$loaded.$key
                }
            }
        }
        catch {}
    }

    [pscustomobject]$state
}

function Save-HardwareOverlayState {
    param(
        [int]$Left,
        [int]$Top,
        [int]$LabelFontSize,
        [int]$ValueFontSize
        )

    $dir = Split-Path $script:HardwareOverlayStatePath
    New-Item -ItemType Directory -Force $dir | Out-Null

    [pscustomobject]@{
        Left = $Left
        Top = $Top
        LabelFontSize = $LabelFontSize
        ValueFontSize = $ValueFontSize
        } | ConvertTo-Json | Set-Content -Encoding UTF8 $script:HardwareOverlayStatePath
    }

    function Write-HardwareOverlayPid {
        param([int]$ProcessId = $PID)

        try {
            $dir = Split-Path $script:HardwareOverlayPidPath
            New-Item -ItemType Directory -Force $dir | Out-Null
            [string]$ProcessId | Set-Content -Encoding ASCII $script:HardwareOverlayPidPath
        }
        catch {}
    }

    function Clear-HardwareOverlayPid {
        param([int]$ProcessId = $PID)

        try {
            if (-not (Test-Path $script:HardwareOverlayPidPath)) { return }

            $stored = [int](Get-Content $script:HardwareOverlayPidPath -Raw)
            if ($stored -eq $ProcessId) {
                Remove-Item $script:HardwareOverlayPidPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }

    function Start-LibreHardwareMonitorIfNeeded {
        param(
            [string]$Url = $script:Monitor.Url,
            [int]$WaitSeconds = 8
            )

        try {
            Invoke-RestMethod $Url -TimeoutSec 1 | Out-Null
            return
        }
        catch {}

        $existing = Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue

        if (-not $existing) {
            $exe = Get-ChildItem `
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
            "$env:ProgramFiles",
            "$env:ProgramFiles(x86)" `
            -Recurse `
            -Filter LibreHardwareMonitor.exe `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName

            if (-not $exe) {
                throw "LibreHardwareMonitor.exe not found. Install it with: winget install LibreHardwareMonitor.LibreHardwareMonitor"
            }

            Start-Process $exe -Verb RunAs | Out-Null
        }

        $deadline = (Get-Date).AddSeconds($WaitSeconds)

        while ((Get-Date) -lt $deadline) {
            try {
                Invoke-RestMethod $Url -TimeoutSec 1 | Out-Null
                return
            }
            catch {
                Start-Sleep -Milliseconds 500
            }
        }

        throw "LibreHardwareMonitor is running, but $Url is unavailable. Enable: Options → Remote Web Server"
    }

    function Send-HardwareOverlayCommand {
        param(
            [ValidateSet('Stop', 'Move', 'Snap', 'FontDelta', 'Batch')]
            [string]$Command = 'Stop',

            [int]$Dx = 0,
            [int]$Dy = 0,
            [int]$Delta = 0,
            [int]$FontDelta = 0,

            [ValidateSet('Left', 'Right', 'Top', 'Bottom', '')]
            [string]$Edge = '',

            [int]$TimeoutMs = 1000,

            [switch]$VerboseLog
            )

        $pipeName = $script:HardwareOverlayPipeName
        if ([string]::IsNullOrWhiteSpace($pipeName)) {
            $pipeName = "HardwareMonitorOverlay-$env:USERNAME"
        }

        $payload = [pscustomobject]@{
            command   = $Command
            dx        = $Dx
            dy        = $Dy
            delta     = $Delta
            fontDelta = $FontDelta
            edge      = $Edge
            } | ConvertTo-Json -Compress

            $client = $null
            $writer = $null
            $reader = $null

            try {
                if ($VerboseLog) { Write-Host "connecting to $pipeName..." -ForegroundColor Cyan }

                $client = [System.IO.Pipes.NamedPipeClientStream]::new(
                    '.',
                    $pipeName,
                    [System.IO.Pipes.PipeDirection]::InOut
                    )

                $client.Connect($TimeoutMs)

                if ($VerboseLog) { Write-Host "connected; sending $Command" -ForegroundColor Cyan }

                $writer = [System.IO.StreamWriter]::new($client)
                $writer.AutoFlush = $true
                $writer.WriteLine($payload)

                if ($VerboseLog) { Write-Host "sent payload: $payload" -ForegroundColor DarkGray }
                if ($VerboseLog) { Write-Host "waiting for ack..." -ForegroundColor Cyan }

                $reader = [System.IO.StreamReader]::new($client)
                [void]$reader.ReadLine()

                if ($VerboseLog) { Write-Host "ack received" -ForegroundColor Green }
            }
            catch {
                throw "Could not send '$Command' to overlay on pipe '$pipeName'. $($_.Exception.Message)"
            }
            finally {
                try { if ($reader) { $reader.Dispose() } } catch {}
                try { if ($writer) { $writer.Dispose() } } catch {}
                try { if ($client) { $client.Dispose() } } catch {}
            }
        }

        function Stop-HardwareOverlayProcess {
            param(
                [int]$TimeoutMs = 300,
                [switch]$NoGraceful
                )

            if (-not $NoGraceful) {
                try {
                    Send-HardwareOverlayCommand -Command Stop -TimeoutMs $TimeoutMs
                    Start-Sleep -Milliseconds 300
                }
                catch {}
            }

            $pidValue = $null

            try {
                if (Test-Path $script:HardwareOverlayPidPath) {
                    $pidValue = [int](Get-Content $script:HardwareOverlayPidPath -Raw)
                }
            }
            catch {}

            if ($pidValue) {
                try {
                    $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
                    if ($proc) {
                        Stop-Process -Id $pidValue -Force
                    }
                }
                catch {}
            }

            try { Remove-Item $script:HardwareOverlayPidPath -Force -ErrorAction SilentlyContinue } catch {}
        }

        function Start-HardwareOverlayControl {
            param(
                [int]$MoveStep = 10,
                [int]$FontStep = 1
                )

            Write-Host "Overlay control mode" -ForegroundColor Cyan
            Write-Host "  Arrows      move"
            Write-Host "  Ctrl+Arrow snap edge"
            Write-Host "  = / -       font +/-"
            Write-Host "  q           quit control mode"
            Write-Host "  Ctrl+q      stop overlay and quit"
            Write-Host ""

            while ($true) {
                $dx = 0
                $dy = 0
                $fontDelta = 0
                $edge = ''
                $stop = $false
                $quit = $false

                do {
                    $key = [Console]::ReadKey($true)
                    $ctrl = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0

                    if ($key.Key -eq 'Q' -and $ctrl) {
                        $stop = $true
                        $quit = $true
                        break
                    }

                    if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') {
                        $quit = $true
                        break
                    }

                    switch ($key.Key) {
                        'LeftArrow'  { if ($ctrl) { $edge = 'Left' }   else { $dx -= $MoveStep } }
                        'RightArrow' { if ($ctrl) { $edge = 'Right' }  else { $dx += $MoveStep } }
                        'UpArrow'    { if ($ctrl) { $edge = 'Top' }    else { $dy -= $MoveStep } }
                        'DownArrow'  { if ($ctrl) { $edge = 'Bottom' } else { $dy += $MoveStep } }
                        'Add'        { $fontDelta += $FontStep }
                        'OemPlus'    { $fontDelta += $FontStep }
                        'Subtract'   { $fontDelta -= $FontStep }
                        'OemMinus'   { $fontDelta -= $FontStep }
                    }
                }
                while ([Console]::KeyAvailable)

                if ($stop) {
                    Send-HardwareOverlayCommand -Command Stop -TimeoutMs 300
                    break
                }

                if ($edge) {
                    Send-HardwareOverlayCommand -Command Snap -Edge $edge
                }
                elseif ($dx -ne 0 -or $dy -ne 0 -or $fontDelta -ne 0) {
                    Send-HardwareOverlayCommand -Command Batch -Dx $dx -Dy $dy -FontDelta $fontDelta
                }

                if ($quit) { break }
            }
        }

        function Start-HardwareLineMonitor {
            param(
                [string]$Url = $script:Monitor.Url,
                [int]$IntervalMs = 500
                )

            Start-LibreHardwareMonitorIfNeeded -Url $Url

            while ($true) {
                try {
                    $snapshot = & $script:Monitor.GetSnapshot $Url
                    $cells = & $script:Monitor.Layout $snapshot
                    & $script:Monitor.RenderConsoleRows $cells
                }
                catch {
                    $top = [Console]::CursorTop
                    [Console]::SetCursorPosition(0, $top)

                    $line = "Hardware monitor unavailable: $($_.Exception.Message)"
                    Write-Host $line.PadRight([Console]::WindowWidth - 1) -ForegroundColor Red -NoNewline

                    if ([Console]::CursorTop -ne $top) {
                        [Console]::SetCursorPosition(0, $top)
                    }
                }

                Start-Sleep -Milliseconds $IntervalMs
            }
        }

        function Start-HardwareOverlay {
            param(
                [string]$Url = $script:Monitor.Url,
                [int]$IntervalMs = 500,
                [int]$Left = 20,
                [int]$Top = 20,
                [int]$Opacity = 145,
                [int]$LabelFontSize = 11,
                [int]$ValueFontSize = 13,
                [switch]$SafeMode,
                [switch]$NoRelaunch
                )

            if (-not $NoRelaunch) {
                $safe = if ($SafeMode) { ' -SafeMode' } else { '' }
                $modulePath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'HardwareMonitor.psm1' }
                $modulePathEscaped = $modulePath.Replace("'", "''")
                $urlEscaped = $Url.Replace("'", "''")

                $cmd = @"
                Import-Module '$modulePathEscaped' -Force
                Start-HardwareOverlay -Url '$urlEscaped' -IntervalMs $IntervalMs -Left $Left -Top $Top -Opacity $Opacity -LabelFontSize $LabelFontSize -ValueFontSize $ValueFontSize -NoRelaunch$safe
"@

                $proc = Start-Process pwsh `
                -WindowStyle Hidden `
                -PassThru `
                -ArgumentList @(
                    '-STA',
                    '-NoLogo',
                    '-NoProfile',
                    '-NonInteractive',
                    '-Command',
                    $cmd
                    )

                if ($proc) {
                    Write-HardwareOverlayPid -ProcessId $proc.Id
                }

                return
            }

            if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
                throw "Start overlay with: pwsh -STA"
            }

            Write-HardwareOverlayPid -ProcessId $PID
            Start-LibreHardwareMonitorIfNeeded -Url $Url

            if (-not $SafeMode) {
                $saved = Get-HardwareOverlayState `
                -DefaultLeft $Left `
                -DefaultTop $Top `
                -DefaultLabelFontSize $LabelFontSize `
                -DefaultValueFontSize $ValueFontSize

                $Left = $saved.Left
                $Top = $saved.Top
                $LabelFontSize = $saved.LabelFontSize
                $ValueFontSize = $saved.ValueFontSize
            }

            Add-Type -AssemblyName PresentationFramework
            Add-Type -AssemblyName PresentationCore
            Add-Type -AssemblyName WindowsBase
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing

            if (-not ('Win32HardwareOverlayNative' -as [type])) {
                Add-Type @"
                using System;
                using System.Runtime.InteropServices;

                public static class Win32HardwareOverlayNative {
                    public const int GWL_EXSTYLE = -20;
                    public const int WS_EX_TRANSPARENT = 0x00000020;
                    public const int WS_EX_LAYERED = 0x00080000;
                    public const int WS_EX_TOOLWINDOW = 0x00000080;
                    public const int WS_EX_NOACTIVATE = 0x08000000;

                    [DllImport("user32.dll")]
                    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

                    [DllImport("user32.dll")]
                    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
                }
"@
            }

            $newTextBlock = {
                param(
                    [string]$Text = "--",
                    [int]$FontSize = 13,
                    [string]$Color = "Gray",
                    [string]$Weight = "Bold"
                    )

                $tb = New-Object Windows.Controls.TextBlock
                $tb.Text = $Text
                $tb.Foreground = $Color
                $tb.FontFamily = "Cascadia Mono"
                $tb.FontSize = $FontSize
                $tb.FontWeight = $Weight
                $tb.HorizontalAlignment = "Center"
                $tb.VerticalAlignment = "Center"
                $tb.TextAlignment = "Center"
                $tb.TextWrapping = "NoWrap"
                $tb.Margin = "0"
                $tb
            }

            $setScaledPadding = {
                param($Control)

                $padX = [Math]::Max(2, [int]($Control.FontSize * 0.35))
                $padY = [Math]::Max(0, [int]($Control.FontSize * 0.08))
                $Control.Padding = "$padX,$padY,$padX,$padY"
            }

            try {
                $initialSnapshot = & $script:Monitor.GetSnapshot $Url
                $initialCells = & $script:Monitor.Layout $initialSnapshot
            }
            catch {
                throw "Could not read LibreHardwareMonitor data from $Url. Is LibreHardwareMonitor Remote Web Server enabled?"
            }

            $window = New-Object Windows.Window
            $window.WindowStyle = "None"
            $window.AllowsTransparency = $true
            $window.Background = [Windows.Media.Brushes]::Transparent
            $window.Topmost = $true
            $window.ShowInTaskbar = $false
            $window.ResizeMode = "NoResize"
            $window.SizeToContent = "WidthAndHeight"
            $window.MinWidth = 0
            $window.MinHeight = 0
            $window.Left = $Left
            $window.Top = $Top

            $panel = New-Object Windows.Controls.Border
            $panel.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb($Opacity, 15, 15, 15))
            $panel.CornerRadius = 10
            $panel.Padding = "10,5,10,5"

            $grid = New-Object Windows.Controls.Grid
            $grid.HorizontalAlignment = "Center"
            $grid.VerticalAlignment = "Center"

            $panel.Child = $grid
            $window.Content = $panel

            $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition)) | Out-Null
            $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition)) | Out-Null

            $labels = @{}
            $values = @{}

            for ($i = 0; $i -lt $initialCells.Count; $i++) {
                $col = New-Object Windows.Controls.ColumnDefinition
                $col.Width = [Windows.GridLength]::Auto
                $grid.ColumnDefinitions.Add($col)
            }

            for ($i = 0; $i -lt $initialCells.Count; $i++) {
                $cell = $initialCells[$i]
                $label = & $newTextBlock $cell.Title $LabelFontSize "Gray" "SemiBold"
                & $setScaledPadding $label
                [Windows.Controls.Grid]::SetColumn($label, $i)
                [Windows.Controls.Grid]::SetRow($label, 0)
                $grid.Children.Add($label) | Out-Null
                $labels[$cell.Title] = $label
            }

            for ($i = 0; $i -lt $initialCells.Count; $i++) {
                $cell = $initialCells[$i]
                $value = & $newTextBlock $cell.Value $ValueFontSize $cell.Color "Bold"
                & $setScaledPadding $value
                [Windows.Controls.Grid]::SetColumn($value, $i)
                [Windows.Controls.Grid]::SetRow($value, 1)
                $grid.Children.Add($value) | Out-Null
                $values[$cell.Title] = $value
            }

        $saveOverlayState = {
            try {
                $firstLabel = @($labels.Values | Select-Object -First 1)[0]
                $firstValue = @($values.Values | Select-Object -First 1)[0]

                if ($firstLabel -and $firstValue) {
                    Save-HardwareOverlayState `
                    -Left ([int]$window.Left) `
                    -Top ([int]$window.Top) `
                    -LabelFontSize ([int]$firstLabel.FontSize) `
                    -ValueFontSize ([int]$firstValue.FontSize)
                }
            }
            catch {}
        }

        $applyFontDelta = {
            param([int]$Delta)

            if ($Delta -eq 0) { return }

            foreach ($label in $labels.Values) {
                $label.FontSize = [Math]::Max(6, $label.FontSize + $Delta)
                & $setScaledPadding $label
            }

            foreach ($value in $values.Values) {
                $value.FontSize = [Math]::Max(6, $value.FontSize + $Delta)
                & $setScaledPadding $value
            }
        }

        $snapOverlay = {
            param([string]$Edge)

            $source = [System.Windows.PresentationSource]::FromVisual($window)
            $scaleX = 1.0
            $scaleY = 1.0

            if ($source -and $source.CompositionTarget) {
                $scaleX = $source.CompositionTarget.TransformToDevice.M11
                $scaleY = $source.CompositionTarget.TransformToDevice.M22
            }

            $centerPhysicalX = [int](($window.Left + ($window.ActualWidth / 2)) * $scaleX)
            $centerPhysicalY = [int](($window.Top + ($window.ActualHeight / 2)) * $scaleY)

            $screen = [System.Windows.Forms.Screen]::FromPoint(
                [System.Drawing.Point]::new($centerPhysicalX, $centerPhysicalY)
                ).WorkingArea

            $left   = $screen.Left   / $scaleX
            $right  = $screen.Right  / $scaleX
            $top    = $screen.Top    / $scaleY
            $bottom = $screen.Bottom / $scaleY

            $w = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
            $h = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { $window.Height }

            $targetLeft = [double]$window.Left
            $targetTop  = [double]$window.Top

            switch ($Edge) {
                'Left'   { $targetLeft = $left }
                'Right'  { $targetLeft = $right - $w }
                'Top'    { $targetTop  = $top }
                'Bottom' { $targetTop  = $bottom - $h }
            }

            $targetLeft = [Math]::Max($left, [Math]::Min($targetLeft, $right - $w))
            $targetTop  = [Math]::Max($top,  [Math]::Min($targetTop,  $bottom - $h))

            $window.Left = $targetLeft
            $window.Top  = $targetTop
        }

        $window.Add_SourceInitialized({
            $hwnd = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
            $style = [Win32HardwareOverlayNative]::GetWindowLong($hwnd, [Win32HardwareOverlayNative]::GWL_EXSTYLE)
            $style = $style -bor [Win32HardwareOverlayNative]::WS_EX_LAYERED -bor [Win32HardwareOverlayNative]::WS_EX_TRANSPARENT -bor [Win32HardwareOverlayNative]::WS_EX_TOOLWINDOW -bor [Win32HardwareOverlayNative]::WS_EX_NOACTIVATE
            [void][Win32HardwareOverlayNative]::SetWindowLong($hwnd, [Win32HardwareOverlayNative]::GWL_EXSTYLE, $style)
            })

        $commandQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

        $handleOverlayCommand = {
            param($msg)


            switch ($msg.command) {
                'Stop' {
                   
                    try { & $saveOverlayState } catch {}
                    $script:OverlayPipeStop = $true
                    try { $timer.Stop() } catch {}
                    try {
                        $tray.Visible = $false
                        $tray.Dispose()
                        } catch {}
                        $window.Close()
                        return
                    }

                    'Move' {
                        $window.Left += [int]$msg.dx
                        $window.Top  += [int]$msg.dy
                    }

                    'Snap' {
                        & $snapOverlay ([string]$msg.edge)
                    }

                    'FontDelta' {
                        & $applyFontDelta ([int]$msg.delta)
                    }

                    'Batch' {
                        if ([int]$msg.dx -ne 0) { $window.Left += [int]$msg.dx }
                        if ([int]$msg.dy -ne 0) { $window.Top  += [int]$msg.dy }
                        if ([int]$msg.fontDelta -ne 0) { & $applyFontDelta ([int]$msg.fontDelta) }
                    }
                }
            }

            $drainOverlayCommands = {
                $queued = $null

                while ($commandQueue.TryDequeue([ref]$queued)) {
                    try {
                        & $handleOverlayCommand $queued
                    }
                    catch {
                    }
                    finally {
                        $queued = $null
                    }
                }
            }

            $timer = New-Object Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)

            $timer.Add_Tick({
                try { & $drainOverlayCommands } catch {}

                try {
                    $snapshot = & $script:Monitor.GetSnapshot $Url
                    $cells = & $script:Monitor.Layout $snapshot

                    foreach ($cell in $cells) {
                        if ($values.ContainsKey($cell.Title)) {
                            $values[$cell.Title].Text = $cell.Value
                            $values[$cell.Title].Foreground = $cell.Color
                        }
                    }
                }
                catch {
                    foreach ($key in $values.Keys) {
                        $values[$key].Text = "--"
                        $values[$key].Foreground = "Red"
                    }
                }
                })

            $tray = New-Object System.Windows.Forms.NotifyIcon
            $tray.Text = "Hardware Overlay"
            $tray.Icon = [System.Drawing.SystemIcons]::Application
            $tray.Visible = $true

            $menu = New-Object System.Windows.Forms.ContextMenuStrip
            $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
            $exitItem.Text = "Exit"

            $exitItem.Add_Click({
                try { & $saveOverlayState } catch {}
                try { $timer.Stop() } catch {}
                try {
                    $tray.Visible = $false
                    $tray.Dispose()
                    } catch {}
                    $window.Close()
                    })

            [void]$menu.Items.Add($exitItem)
            $tray.ContextMenuStrip = $menu

            $tray.Add_DoubleClick({
                try { & $saveOverlayState } catch {}
                try { $timer.Stop() } catch {}
                try {
                    $tray.Visible = $false
                    $tray.Dispose()
                    } catch {}
                    $window.Close()
                    })

            $script:OverlayPipeStop = $false

            $pipeRunspace = [runspacefactory]::CreateRunspace()
            $pipeRunspace.ApartmentState = 'MTA'
            $pipeRunspace.ThreadOptions = 'ReuseThread'
            $pipeRunspace.Open()

            $pipePs = [powershell]::Create()
            $pipePs.Runspace = $pipeRunspace
            $pipeCancel = [System.Threading.CancellationTokenSource]::new()

            $null = $pipePs.AddScript({
                param($pipeName, $queue, $cancelToken)

                while (-not $cancelToken.IsCancellationRequested) {
                    $server = $null
                    $reader = $null
                    $writer = $null

                    try {
                        $server = [System.IO.Pipes.NamedPipeServerStream]::new(
                            $pipeName,
                            [System.IO.Pipes.PipeDirection]::InOut,
                            1,
                            [System.IO.Pipes.PipeTransmissionMode]::Byte,
                            [System.IO.Pipes.PipeOptions]::Asynchronous
                            )

                        $task = $server.WaitForConnectionAsync($cancelToken)
                        $task.GetAwaiter().GetResult()

                        if ($cancelToken.IsCancellationRequested) {
                            break
                        }

                        $reader = [System.IO.StreamReader]::new($server)
                        $writer = [System.IO.StreamWriter]::new($server)
                        $writer.AutoFlush = $true

                        $raw = $reader.ReadLine()

                        if ([string]::IsNullOrWhiteSpace($raw)) {
                            try { $writer.WriteLine("EMPTY") } catch {}
                            continue
                        }

                        $msg = $raw | ConvertFrom-Json

                # ACK before the UI thread handles the command, especially Stop.
                try { $writer.WriteLine("OK") } catch {}

                $queue.Enqueue($msg)

                if ($msg.command -eq "Stop") {
                    break
                }
            }
            catch [System.OperationCanceledException] {
                break
            }
            catch {
                Start-Sleep -Milliseconds 150
            }
            finally {
                try { if ($reader) { $reader.Dispose() } } catch {}
                try { if ($writer) { $writer.Dispose() } } catch {}
                try { if ($server) { $server.Dispose() } } catch {}
            }
        }
        }).AddArgument($script:HardwareOverlayPipeName).
            AddArgument($commandQueue).
            AddArgument($pipeCancel.Token)

            $pipeAsync = $pipePs.BeginInvoke()

            $window.Add_Closed({
                try { & $saveOverlayState } catch {}
                $script:OverlayPipeStop = $true
                try { $pipeCancel.Cancel() } catch {}
                try { $timer.Stop() } catch {}
                try {
                    $tray.Visible = $false
                    $tray.Dispose()
                    } catch {}
                    Clear-HardwareOverlayPid -ProcessId $PID
                    })

            $timer.Start()
            $window.ShowDialog() | Out-Null

            try { $timer.Stop() } catch {}
            try { $pipeCancel.Cancel() } catch {}

            try {
                if ($pipeAsync -and -not $pipeAsync.IsCompleted) {
                    [void]$pipeAsync.AsyncWaitHandle.WaitOne(1000)
                }
                } catch {}

                try {
                    if ($pipePs) {
                        if ($pipeAsync -and $pipeAsync.IsCompleted) {
                            $pipePs.EndInvoke($pipeAsync)
                        }
                        else {
                            $pipePs.Stop()
                        }
                        $pipePs.Dispose()
                    }
                    } catch {
                        try { $pipePs.Stop() } catch {}
                        try { $pipePs.Dispose() } catch {}
                    }

                    try {
                        if ($pipeRunspace) {
                            $pipeRunspace.Close()
                            $pipeRunspace.Dispose()
                        }
                        } catch {}

                        try { $pipeCancel.Dispose() } catch {}
                        Clear-HardwareOverlayPid -ProcessId $PID

                        if ($NoRelaunch) {
                            [Environment]::Exit(0)
                        }
                    }

                    Set-Alias ho Start-HardwareOverlay
                    Set-Alias hoc Start-HardwareOverlayControl
                    Set-Alias hos Send-HardwareOverlayCommand
                    Set-Alias hok Stop-HardwareOverlayProcess

                    Export-ModuleMember `
                    -Function Start-HardwareLineMonitor, Start-HardwareOverlay, Send-HardwareOverlayCommand, Start-HardwareOverlayControl, Stop-HardwareOverlayProcess `
                    -Alias ho, hoc, hos, hok


