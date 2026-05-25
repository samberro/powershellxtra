# Unit tests for PowerShellXtra 'cd' logic (Pester 3.4.0 compatible)

Describe "Smart CD Logic" {
    BeforeAll {
        function Test-SmartCD {
            param($SearchTerm, $MockHistory, $MockPaths, $SearchRoots, $ResolveDepth = 1, $MatchPrefixOnly = $true)
            
            function Resolve-MockPath {
                param($Raw, $Depth, $History, $KnownPaths, $Roots, $Seen)
                
                $p = $Raw -replace "^~", "C:\Users\sambe"
                $safeP = [Management.Automation.WildcardPattern]::Escape($p)
                # Mock Test-Path behavior
                if ($KnownPaths -contains $p) { return $p }
                if ($Depth -le 0) { return $null }
                
                $parts = $p -split '[\\/]' | Where-Object { $_ -and $_ -ne "." -and $_ -ne ".." }
                if ($parts.Count -eq 0) { return $null }
                $topDir = $parts[0]
                
                if ($Seen -contains $topDir) { return $null }
                $newSeen = $Seen + $topDir

                # 1. Check fixed roots
                foreach ($r in $Roots) {
                    $cand = "$r\$topDir"
                    if ($KnownPaths -contains $cand) {
                        $tailParts = $parts[1..($parts.Count-1)]
                        $full = $cand
                        if ($tailParts) {
                            foreach($tp in $tailParts) { $full = "$full\$tp" }
                        }
                        if ($KnownPaths -contains $full) { return $full }
                    }
                }

                # 2. Check history for topDir
                $escapedTop = [Regex]::Escape($topDir)
                $pattern = "(?:cd|PS)\s+(['""]?[^'""\s]*$escapedTop.*?)(?:>?\\?)$"
                foreach ($line in $History) {
                    if ($line -match $pattern) {
                        $hPath = $Matches[1] -replace "['""]", ""
                        $resolvedHistoryPath = Resolve-MockPath -Raw $hPath -Depth ($Depth - 1) -History $History -KnownPaths $KnownPaths -Roots $Roots -Seen $newSeen
                        
                        if ($resolvedHistoryPath) {
                            $hSegments = $resolvedHistoryPath -split '[\\/]'
                            $basePath = $null
                            for ($i = 0; $i -lt $hSegments.Count; $i++) {
                                # Correct .IndexOf usage for case-insensitivity
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
                                    foreach($tp in $tailParts) { $full = "$full\$tp" }
                                }
                                if ($KnownPaths -contains $full) { return $full }
                            }
                        }
                    }
                }
                return $null
            }

            $Path = $SearchTerm -replace "['""]", ""
            if ($MockPaths -contains $Path) { return $Path }

            $candidates = @()
            $seenPaths = @{}

            # Search history for candidates
            $escapedSearch = [Regex]::Escape($SearchTerm)
            $pattern = if ($MatchPrefixOnly) {
                "(?:cd|PS)\s+(['""]?[^'""\s]*(?:\\|/|^)$escapedSearch.*?)(?:>?\\?)$"
            } else {
                "(?:cd|PS)\s+(['""]?[^'""\s]*$escapedSearch.*?)(?:>?\\?)$"
            }

            foreach ($line in $MockHistory) {
                if ($line -match $pattern) {
                    $rawHistoryPath = $Matches[1] -replace "['""]", ""
                    $resolvedPath = Resolve-MockPath -Raw $rawHistoryPath -Depth $ResolveDepth -History $MockHistory -KnownPaths $MockPaths -Roots $SearchRoots -Seen @()

                    if ($resolvedPath -and -not $seenPaths.ContainsKey($resolvedPath)) {
                        $seenPaths[$resolvedPath] = $true
                        $segments = $resolvedPath -split '[\\/]'
                        for ($i = 0; $i -lt $segments.Count; $i++) {
                            $matchesTarget = if ($MatchPrefixOnly) {
                                $segments[$i].StartsWith($SearchTerm, [System.StringComparison]::CurrentCultureIgnoreCase)
                            } else {
                                # Correct .IndexOf usage for case-insensitivity
                                $segments[$i].IndexOf($SearchTerm, [System.StringComparison]::CurrentCultureIgnoreCase) -ge 0
                            }

                            if ($matchesTarget) {
                                $parentPath = ($segments[0..$i] -join "\")
                                if ($MockPaths -contains $parentPath) {
                                    $folderName = $segments[$i]
                                    $score = 10 
                                    if ($folderName.Equals($SearchTerm, [System.StringComparison]::CurrentCultureIgnoreCase)) { $score += 100 }
                                    elseif ($folderName.StartsWith($SearchTerm, [System.StringComparison]::CurrentCultureIgnoreCase)) { $score += 50 }
                                    
                                    $candidates += [PSCustomObject]@{
                                        Path = $parentPath
                                        Score = $score
                                        Depth = $i
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if ($candidates) {
                $best = $candidates | Sort-Object @{Expression="Score";Descending=$true}, @{Expression="Depth";Descending=$false} | Select-Object -First 1
                return $best.Path
            }
            return $null
        }
    }

    #Do not remove tests... only add to them,... 
    #Add a '#x >' to the end of name so tests print like:
    #[+] Should prefer parent directory over subdirectories  #1 > 181ms
    It "Should prefer parent directory over subdirectories  #1 >" {
        $mockHistory = @("cd C:\Projects\my_dir\temp\", "cd C:\Projects\my_dir\src\")
        $mockPaths = @("C:\Projects\my_dir", "C:\Projects\my_dir\temp", "C:\Projects\my_dir\src")
        
        $result = Test-SmartCD -SearchTerm "my_dir" -MockHistory $mockHistory -MockPaths $mockPaths
        $result | Should Be "C:\Projects\my_dir"
    }

    It "Should resolve broken paths by finding the top-most directory in roots #2 >" {
        $mockHistory = @("cd .\parent2\parent1\erome_crawler\")
        $searchRoots = @("C:\Users\sambe\Documents\PowerShell")
        $mockPaths = @(
            "C:\Users\sambe\Documents\PowerShell\parent2",
            "C:\Users\sambe\Documents\PowerShell\parent2\parent1",
            "C:\Users\sambe\Documents\PowerShell\parent2\parent1\erome_crawler"
        )
        
        $result = Test-SmartCD -SearchTerm "erome" -MockHistory $mockHistory -MockPaths $mockPaths -SearchRoots $searchRoots
        $result | Should Be "C:\Users\sambe\Documents\PowerShell\parent2\parent1\erome_crawler"
    }

    It "Should resolve broken paths using other history #3 >" {
        $mockHistory = @("cd .\parent2\parent1\erome_crawler\", "cd ~\Documents\PowerShell\parent2\")
        $mockPaths = @(
            "C:\Users\sambe\Documents\PowerShell\parent2",
            "C:\Users\sambe\Documents\PowerShell\parent2\parent1",
            "C:\Users\sambe\Documents\PowerShell\parent2\parent1\erome_crawler"
        )
        
        $result = Test-SmartCD -SearchTerm "erome" -MockHistory $mockHistory -MockPaths $mockPaths
        $result | Should Be "C:\Users\sambe\Documents\PowerShell\parent2\parent1\erome_crawler"
    }

     It "Should resolve broken paths recursively and land on the matching segment #4.a >" {
        $mockHistory = @(
            "cd .\p3\p2\p1\my_dir\temp\", 
            "cd .\p3\p2\", 
            "cd C:\Projects\p3\o2"
        )
        $mockPaths = @(
            "C:\Projects\p3",
            "C:\Projects\p3\o2",
            "C:\Projects\p3\p2",
            "C:\Projects\p3\p2\p1",
            "C:\Projects\p3\p2\p1\my_dir",
            "C:\Projects\p3\p2\p1\my_dir\temp"
        )
        
        $result = Test-SmartCD -SearchTerm "my_dir" -MockHistory $mockHistory -MockPaths $mockPaths -ResolveDepth 1
        $result | Should Be "C:\Projects\p3\p2\p1\my_dir"
    }

        It "Should resolve broken paths recursively and land on the matching segment  (multi-depth) #4.b >" {
        $mockHistory = @(
            "cd .\p2\p1\my_dir\temp\", 
            "cd .\p3\p2\", 
            "cd C:\Projects\p3\o2"
        )
        $mockPaths = @(
            "C:\Projects\p3",
            "C:\Projects\p3\o2",
            "C:\Projects\p3\p2",
            "C:\Projects\p3\p2\p1",
            "C:\Projects\p3\p2\p1\my_dir",
            "C:\Projects\p3\p2\p1\my_dir\temp"
        )
        
        $result = Test-SmartCD -SearchTerm "my_dir" -MockHistory $mockHistory -MockPaths $mockPaths -ResolveDepth 2
        $result | Should Be "C:\Projects\p3\p2\p1\my_dir"
    }

    It "Should honor prefix-only matching (MatchPrefixOnly = true) #5.a >" {
        $mockHistory = @("cd C:\Projects\LMS+ComfyUI", "cd C:\Projects\ComfyUI-Manager")
        $mockPaths = @("C:\Projects\LMS+ComfyUI", "C:\Projects\ComfyUI-Manager")
        
        $result = Test-SmartCD -SearchTerm "comfy" -MockHistory $mockHistory -MockPaths $mockPaths -MatchPrefixOnly $true
        $result | Should Be "C:\Projects\ComfyUI-Manager"
    }

    It "Should allow mid-path matching when prefix-only is disabled (MatchPrefixOnly = false) #5.b >" {
        $mockHistory = @("cd C:\Projects\LMS+ComfyUI")
        $mockPaths = @("C:\Projects\LMS+ComfyUI")
        
        $result = Test-SmartCD -SearchTerm "comfy" -MockHistory $mockHistory -MockPaths $mockPaths -MatchPrefixOnly $false
        $result | Should Be "C:\Projects\LMS+ComfyUI"
    }

    It "Should handle special characters [, ), } in paths correctly #6 >" {
        $mockHistory = @("cd C:\Projects\test[v1]\folder(sub)\brace{tail}")
        $mockPaths = @(
            "C:\Projects\test[v1]",
            "C:\Projects\test[v1]\folder(sub)",
            "C:\Projects\test[v1]\folder(sub)\brace{tail}"
        )
        
        # Test finding the folder with [
        $result1 = Test-SmartCD -SearchTerm "test[v1]" -MockHistory $mockHistory -MockPaths $mockPaths
        $result1 | Should Be "C:\Projects\test[v1]"
        
        # Test finding the folder with (
        $result2 = Test-SmartCD -SearchTerm "folder(sub)" -MockHistory $mockHistory -MockPaths $mockPaths
        $result2 | Should Be "C:\Projects\test[v1]\folder(sub)"
        
        # Test finding the folder with {
        $result3 = Test-SmartCD -SearchTerm "brace{tail}" -MockHistory $mockHistory -MockPaths $mockPaths
        $result3 | Should Be "C:\Projects\test[v1]\folder(sub)\brace{tail}"
    }
}
