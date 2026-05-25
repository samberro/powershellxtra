$line = "cd C:\Projects\LMS+ComfyUI"
$SearchTerm = "comfy"
$escapedSearch = [Regex]::Escape($SearchTerm)

Write-Host "Testing Mid-Path (MatchPrefixOnly = false):"
$pattern1 = "(?:cd|PS)\s+(['""]?[^'""\s]*$escapedSearch.*?)(?:>?\\?)$"
if ($line -match $pattern1) {
    Write-Host "  MATCH: $($Matches[1])" -ForegroundColor Green
} else {
    Write-Host "  NO MATCH" -ForegroundColor Red
}

Write-Host "`nTesting Prefix-Only (MatchPrefixOnly = true):"
$pattern2 = "(?:cd|PS)\s+(['""]?[^'""\s]*(?:\\|/|^)$escapedSearch.*?)(?:>?\\?)$"
if ($line -match $pattern2) {
    Write-Host "  MATCH: $($Matches[1])" -ForegroundColor Green
} else {
    Write-Host "  NO MATCH (Correct behavior for prefix-only)" -ForegroundColor Gray
}

Write-Host "`nTesting LMS+ComfyUI exact match in loop:"
$resolvedPath = "C:\Projects\LMS+ComfyUI"
$segments = $resolvedPath -split '[\\/]'
foreach ($s in $segments) {
    $contains = $s.Contains($SearchTerm)
    $startsWith = $s.StartsWith($SearchTerm, "CurrentCultureIgnoreCase")
    Write-Host "  Segment: $s | Contains: $contains | StartsWith: $startsWith"
}
