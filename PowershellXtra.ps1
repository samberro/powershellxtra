# PowerShellXtra.ps1 - Extra PowerShell utilities

# Global state
$global:LastPromptPath = $null
$global:ManualDeactivatePath = $null
$global:LastVenv = $null
$global:CD_ResolveDepth = 2 # Configurable depth for recursive path resolution
$global:CD_MatchPrefixOnly = $true # If true, matches 'query*' instead of '*query*'
# Dynamically find project search roots
$global:CD_SearchRoots = @("$HOME\Documents\PowerShell", "$HOME\Documents")
$global:CD_SearchRoots += Get-ChildItem $HOME -Directory -Filter "*Projs" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName

$global:XtraState = [hashtable]::Synchronized(@{
    ActiveCommand = $null
    CurrentPath = $PWD.Path
})

# Create a persistent runspace for background title updates
if (-not $global:TitleRunspace) {
    $global:TitleRunspace = [RunspaceFactory]::CreateRunspace()
    $global:TitleRunspace.Open()
}

# --- Utilities ---

function cd {
    <#
    .SYNOPSIS
        A smart wrapper for Set-Location that leverages PSReadLine history with recursive resolution.
    #>
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string]$Path
    )

    # Internal helper for recursive resolution
    function Resolve-SmartPath {
        param($Raw, $Depth, $History, $Roots, $Seen, [ref]$ResolutionLevels)
        
        $p = $Raw -replace "^~", $HOME
        $safeP = [Management.Automation.WildcardPattern]::Escape($p)
        if (Test-Path $safeP) { return (Resolve-Path $safeP).Path }
        if ($Depth -le 0) { return $null }
        
        $parts = $p -split '[\\/]' | Where-Object { $_ -and $_ -ne "." -and $_ -ne ".." }
        if ($parts.Count -eq 0) { return $null }
        $topDir = $parts[0]
        
        if ($Seen -contains $topDir) { return $null }
        $newSeen = $Seen + $topDir

        # 1. Check fixed roots
        foreach ($r in $Roots) {
            $cand = Join-Path $r $topDir
            $safeCand = [Management.Automation.WildcardPattern]::Escape($cand)
            if (Test-Path $safeCand) {
                $tailParts = $parts[1..($parts.Count-1)]
                $full = $cand
                if ($tailParts) {
                    foreach($tp in $tailParts) { $full = Join-Path $full $tp }
                }
                $safeFull = [Management.Automation.WildcardPattern]::Escape($full)
                if (Test-Path $safeFull) { return (Resolve-Path $safeFull).Path }
            }
        }

        # 2. Check history for topDir (The "Recursive" part)
        $escapedTop = [Regex]::Escape($topDir)
        # Permissive class: match anything except quotes and space before the target
        $pattern = "(?:cd|PS)\s+(['""]?[^'""\s]*$escapedTop.*?)(?:>?\\?)$"
        foreach ($line in $History) {
            if ($line -match $pattern) {
                $hPath = $Matches[1] -replace "['""]", ""
                
                $childLevels = 0
                $resolvedHistoryPath = Resolve-SmartPath -Raw $hPath -Depth ($Depth - 1) -History $History -Roots $Roots -Seen $newSeen -ResolutionLevels ([ref]$childLevels)
                
                if ($resolvedHistoryPath) {
                    $ResolutionLevels.Value = $childLevels + 1
                    # Spec 3 Upgrade: Find where topDir is in the resolved history path and truncate
                    $hSegments = $resolvedHistoryPath -split '[\\/]'
                    $basePath = $null
                    for ($i = 0; $i -lt $hSegments.Count; $i++) {
                        if ($hSegments[$i].Equals($topDir, [System.StringComparison]::CurrentCultureIgnoreCase) -or 
                            $hSegments[$i].IndexOf($topDir, [System.StringComparison]::CurrentCultureIgnoreCase) -ge 0) {
                            $basePath = $hSegments[0..$i] -join "\"
                            break
                        }
                    }

                    if ($basePath) {
                        $tailParts = $parts[1..($parts.Count-1)]
                        $full = $basePath
                        if ($tailParts) {
                            foreach($tp in $tailParts) { $full = Join-Path $full $tp }
                        }
                        $safeFull = [Management.Automation.WildcardPattern]::Escape($full)
                        if (Test-Path $safeFull) { return (Resolve-Path $safeFull).Path }
                    }
                }
            }
        }
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Set-Location $HOME
        return
    }

    $Path = $Path -replace "['""]", ""

    # 1. Standard behavior
    $safePathInput = [Management.Automation.WildcardPattern]::Escape($Path)
    if (Test-Path $safePathInput) {
        Set-Location $Path
        return
    }

    # 2. Advanced History & Heuristic Lookup
    $historyFile = (Get-PSReadLineOption).HistorySavePath
    if (Test-Path $historyFile) {
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $history = [System.IO.File]::ReadLines($historyFile) | Select-Object -Last 1000
            $candidates = @()
            $seenPaths = @{}
            
            $resolveDepth = $global:CD_ResolveDepth
            $searchRoots = $global:CD_SearchRoots

            $escapedPath = [Regex]::Escape($Path)
            $globRegex = $escapedPath -replace '\\\*', '.*' -replace '\\\?', '.'
            
            $isValidRegex = $true
            try { [regex]$Path | Out-Null } catch { $isValidRegex = $false }

            $searchTerms = @($escapedPath)
            if ($globRegex -ne $escapedPath) { $searchTerms += $globRegex }
            if ($isValidRegex -and $Path -ne $escapedPath) { $searchTerms += $Path }
            $combinedTerm = "(?:" + ($searchTerms -join "|") + ")"

            # Conditional anchoring based on prefix-only preference
            $pattern = if ($global:CD_MatchPrefixOnly) {
                "(?:cd|PS)\s+(['""]?[^'""\s]*(?:\\|/|^)$combinedTerm.*?)(?:>?\\?)$"
            } else {
                "(?:cd|PS)\s+(['""]?[^'""\s]*$combinedTerm.*?)(?:>?\\?)$"
            }

            foreach ($line in $history) {
                if ($line -match $pattern) {
                    $rawHistoryPath = $Matches[1] -replace "['""]", ""
                    $levels = 0
                    $resolvedPath = Resolve-SmartPath -Raw $rawHistoryPath -Depth $resolveDepth -History $history -Roots $searchRoots -Seen @() -ResolutionLevels ([ref]$levels)

                    if ($resolvedPath -and -not $seenPaths.ContainsKey($resolvedPath)) {
                        $seenPaths[$resolvedPath] = $true
                        
                        $segments = $resolvedPath -split '[\\/]'
                        for ($i = 0; $i -lt $segments.Count; $i++) {
                            $pathSegmentsCount = ($Path -split '[\\/]' | Where-Object { $_ }).Count
                            if ($pathSegmentsCount -eq 0) { $pathSegmentsCount = 1 }
                            $startIdx = [Math]::Max(0, $i - $pathSegmentsCount + 1)
                            $targetString = $segments[$startIdx..$i] -join "\"

                            $matchesTarget = $false
                            if ($global:CD_MatchPrefixOnly) {
                                if ($targetString -match "^$combinedTerm") { $matchesTarget = $true }
                            } else {
                                if ($targetString -match $combinedTerm) { $matchesTarget = $true }
                            }
                            if (-not $matchesTarget) {
                                $likeFilter = if ($global:CD_MatchPrefixOnly) { "$Path*" } else { "*$Path*" }
                                if ($targetString -like $likeFilter) { $matchesTarget = $true }
                            }

                            if ($matchesTarget) {
                                $parentPath = ($segments[0..$i] -join "\")
                                $safeParent = [Management.Automation.WildcardPattern]::Escape($parentPath)
                                if (Test-Path $safeParent) {
                                    $folderName = $segments[$i]
                                    $score = 10 
                                    if ($folderName.Equals($Path, [System.StringComparison]::CurrentCultureIgnoreCase)) { $score += 100 }
                                    elseif ($folderName.StartsWith($Path, [System.StringComparison]::CurrentCultureIgnoreCase)) { $score += 50 }
                                    
                                    $candidates += [PSCustomObject]@{
                                        Path  = $parentPath
                                        Score = $score
                                        Levels = $levels
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if ($candidates) {
                $sw.Stop()
                $best = $candidates | Sort-Object @{Expression="Score";Descending=$true}, @{Expression="Levels";Descending=$false} | Select-Object -First 1
                Write-Host "Found in history: $($best.Path) [p$($best.Levels)|$($sw.ElapsedMilliseconds)ms]" -ForegroundColor Cyan
                Set-Location $best.Path
                return
            }
        } catch {
            Write-Warning "History search failed: $_"
        }
    }

    # 3. Fallback: Standard wildcard search in common locations
    $filter = if ($global:CD_MatchPrefixOnly) { "$Path*" } else { "*$Path*" }
    foreach ($root in $global:CD_SearchRoots) {
        if (Test-Path $root) {
            $match = Get-ChildItem $root -Directory -Filter $filter -ErrorAction SilentlyContinue | 
                     Sort-Object { $_.FullName.Length } | 
                     Select-Object -First 1
            if ($match) {
                Write-Host "Found in ${root}: $($match.FullName)" -ForegroundColor Cyan
                Set-Location $match.FullName
                return
            }
        }
    }

    # 4. Final Fallback
    Set-Location $Path
}

function Update-TabTitle {
    param($Path)
    
    # Idle prompt: ..parent\child logic
    $parts = $Path -split '\\'
    if ($parts.Count -gt 2) {
        $title = ".." + $parts[-2] + "\" + $parts[-1]
    } else {
        $title = $Path
    }
    $Host.UI.RawUI.WindowTitle = $title
}

# --- Prompt Function ---

function prompt {

    $currentPath = $PWD.Path
    $global:XtraState.ActiveCommand = $null
    $global:XtraState.CurrentPath = $currentPath

    $dirChanged = $currentPath -ne $global:LastPromptPath
    
    # 1. Detect Manual Deactivation
    if ($global:LastVenv -and -not $env:VIRTUAL_ENV) {
        $global:ManualDeactivatePath = $currentPath
    }
    $global:LastVenv = $env:VIRTUAL_ENV

    # 2. Python Virtual Environment Management
    if ($env:VIRTUAL_ENV) {
        $venvDir = Get-Item $env:VIRTUAL_ENV -ErrorAction SilentlyContinue
        if ($venvDir) {
            $projectRoot = $venvDir.Parent.FullName
            if ($currentPath -notlike "$projectRoot*") {
                if (Test-Path function:deactivate) { deactivate | Out-Null }
                else { $env:VIRTUAL_ENV = $null }
                $global:LastVenv = $null
            }
        }
    } elseif ($dirChanged) {
        if ($currentPath -ne $global:ManualDeactivatePath) {
            # Inline check for venv to be fast
            $venvNames = @(".venv", "venv", "env", ".env")
            $foundVenv = $null
            $curr = Get-Item $currentPath -ErrorAction SilentlyContinue
            while ($curr) {
                foreach ($name in $venvNames) {
                    $cand = Join-Path $curr.FullName $name
                    if (Test-Path (Join-Path $cand "Scripts\Activate.ps1")) { $foundVenv = $cand; break }
                }
                if ($foundVenv) { break }
                $curr = $curr.Parent
            }

            if ($foundVenv) {
                $activateScript = Join-Path $foundVenv "Scripts\Activate.ps1"
                . $activateScript | Out-Null
                $global:ManualDeactivatePath = $null
                $global:LastVenv = $env:VIRTUAL_ENV
            }
        }
    }

    # 3. Tab Title (Idle)
    Update-TabTitle -Path $currentPath

    # 4. Render Prompt
    $global:LastPromptPath = $currentPath
    if( -not (Test-Path -Path Function:_OLD_VIRTUAL_PROMPT)) {
        $venvIndicator = if ($env:VIRTUAL_ENV) { "($(Split-Path $env:VIRTUAL_ENV -Leaf)) " } else { "" }
        
        Write-Host "" # New line
        if ($venvIndicator) { Write-Host -NoNewline $venvIndicator -ForegroundColor Cyan }
        Write-Host -NoNewline "PS " -ForegroundColor Green
        Write-Host -NoNewline $currentPath -ForegroundColor Yellow
        Write-Host -NoNewline "> "
    }    
    return ""
}

# --- Force Alias Override ---
# PowerShell aliases take precedence over functions. 
# We must remove the 'cd' alias so our function is used.
if (Get-Alias cd -ErrorAction SilentlyContinue) {
    Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue
}

# --- Process Execution Hook ---

if (Get-Module PSReadLine) {
    Set-PSReadLineOption -AddToHistoryHandler {
        param($command)
        
        $global:XtraState.ActiveCommand = $command
        $instantCommands = @('ls', 'dir', 'cd', 'pwd', 'cls', 'clear', 'history', 'echo', 'exit')
        $firstWord = ($command.Trim() -split ' ')[0]
        
        if ($instantCommands -notcontains $firstWord) {
            # Start background monitor
            $ps = [PowerShell]::Create().AddScript({
                param($ShellPid, $FullCommand, $State)
                
                # Wait for process to be "long running"
                Start-Sleep -Milliseconds 1300
                
                # Verify if this command is still active
                if ($State.ActiveCommand -ne $FullCommand) { return }

                # Check for child processes
                $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ShellPid" -ErrorAction SilentlyContinue
                if (-not $children) { return }
                
                # Server Detection
                $childPids = $children | Select-Object -ExpandProperty ProcessId
                $connection = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | 
                              Where-Object { $childPids -contains $_.OwningProcess } | 
                              Select-Object -First 1
                
                $procName = ($FullCommand.Trim() -split ' ')[0]
                $folderName = Split-Path $State.CurrentPath -Leaf
                
                if ($connection) {
                    $title = "($procName|${folderName}:$($connection.LocalPort)) $FullCommand"
                } else {
                    $title = "$FullCommand"
                }
                
                [Console]::Title = $title

            }).AddArgument($PID).AddArgument($command).AddArgument($global:XtraState)
            
            $ps.Runspace = $global:TitleRunspace
            $ps.BeginInvoke()
        }
        
        return $true 
    }
}
