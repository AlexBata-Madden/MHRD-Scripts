<#
.SYNOPSIS
Checks MHRD circuit files and reports errors in a format VS Code understands.

.DESCRIPTION
The linter recognises two kinds of files:

1. Implemented circuits, which must contain Inputs, Outputs, Parts, and Wires.
2. Interface specifications, which contain the Interface Specification header,
   its divider, Inputs, and Outputs only.

VS Code runs this script with -Watch. Each reported line has this shape:
path:line:column rule-code explanation

.PARAMETER Path
Files or directories to check. By default, the whole repository is scanned.

.PARAMETER Format
Print human-readable text for VS Code, or JSON for another program to consume.

.PARAMETER Watch
Keep running and lint again whenever a circuit file is saved, created, or deleted.

.PARAMETER DebounceMilliseconds
Wait this long after a file event so editors have time to finish saving the file.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path = @('.'),

    [ValidateSet('text', 'json')]
    [string]$Format = 'text',

    [switch]$Watch,

    [int]$DebounceMilliseconds = 200
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# These are the project's linting conventions. They live here rather than in a
# separate config file so the complete linter only needs this one script.
$settings = @{
    indentStyle = 'spaces'
    indentSize = 4
    requireInputsAtTop = $true
    requireAllSections = $true
    allowInterfaceSpecifications = $true
    interfaceDivider = '------------------------'
    requireInterfaceOutputsLast = $true
}

# These folders contain repository tooling rather than MHRD circuit files. Paths
# are compared using forward slashes because Get-RelativeLintPath normalises them.
$ignoredPathPrefixes = @('.git/', '.vscode/', 'tools/', 'assets/')

# VS Code needs paths relative to the open workspace to associate an error with
# the correct editor tab. Forward slashes work consistently in its Problems panel.
function Get-RelativeLintPath {
    param([string]$FullName)
    $current = (Get-Location).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $relative = ([Uri]$current).MakeRelativeUri([Uri]$FullName).ToString()
    return [Uri]::UnescapeDataString($relative).Replace('\', '/')
}

# Return true for paths that belong to repository infrastructure rather than the
# circuit source tree. This lets new top-level groups such as Memory work without
# needing to update the linter each time.
function Test-IgnoredLintPath {
    param([string]$RelativePath)
    foreach ($prefix in $ignoredPathPrefixes) {
        if ($RelativePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Add one consistently shaped diagnostic to the shared list. The tasks.json
# problem matcher reads these fields after they are printed by Invoke-MhrdLint.
function Add-Issue {
    param(
        [Collections.Generic.List[object]]$Issues,
        [string]$File,
        [int]$Line,
        [int]$Column,
        [string]$Rule,
        [string]$Message
    )
    $Issues.Add([pscustomobject][ordered]@{
        file    = $File
        line    = $Line
        column  = $Column
        rule    = $Rule
        message = $Message
    })
}

# Convert Windows, Linux, and old-style line endings into the same representation.
# Trailing empty lines are removed because section placement uses content lines.
function Get-ContentLines {
    param([string]$Content)
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    # MHRD ignores everything from // to the end of a line. Strip comments while
    # retaining the line itself so diagnostics still report the original number.
    $lines = @($normalized.Split("`n") | ForEach-Object {
        $commentStart = $_.IndexOf('//', [StringComparison]::Ordinal)
        if ($commentStart -ge 0) { $_.Substring(0, $commentStart) } else { $_ }
    })
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { return @() }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return $lines
}

# Validate a section whose entire list is on its header line, for example:
# Inputs: in1, in2;
function Test-InlineList {
    param(
        [string[]]$Lines,
        [hashtable]$Positions,
        [string]$Name,
        [string]$Rule,
        [string]$File,
        [Collections.Generic.List[object]]$Issues
    )
    if (-not $Positions.ContainsKey($Name)) { return }

    # Positions contains zero-based array indexes. Add-Issue receives one-based
    # line numbers because that is what editors display.
    $index = [int]$Positions[$Name]
    $pattern = '^' + [regex]::Escape($Name) + ':\s*(?<items>.+);\s*$'
    $match = [regex]::Match($Lines[$index], $pattern)
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups['items'].Value)) {
        Add-Issue $Issues $File ($index + 1) 1 $Rule "$Name must contain a non-empty inline list ending with ';'."
    }
}

# Validate a multi-line Parts or Wires list. Blank lines may visually group items,
# but every non-blank item must be indented and correctly punctuated.
function Test-IndentedList {
    param(
        [string[]]$Lines,
        [hashtable]$Positions,
        [string]$Name,
        [string]$NextName,
        [string]$Rule,
        [string]$File,
        [Collections.Generic.List[object]]$Issues
    )
    if (-not $Positions.ContainsKey($Name)) { return }
    $headerIndex = [int]$Positions[$Name]
    if ($Lines[$headerIndex] -notmatch ('^' + [regex]::Escape($Name) + ':\s*$')) {
        Add-Issue $Issues $File ($headerIndex + 1) 1 $Rule "$Name header must end with ':'."
    }

    # Parts ends where Wires begins. Wires has no following section, so it ends at
    # the end of the file.
    $end = $Lines.Count
    if ($NextName -and $Positions.ContainsKey($NextName)) { $end = [int]$Positions[$NextName] }
    $entries = [Collections.Generic.List[int]]::new()
    for ($index = $headerIndex + 1; $index -lt $end; $index++) {
        if (-not [string]::IsNullOrWhiteSpace($Lines[$index])) { $entries.Add($index) }
    }
    if ($entries.Count -eq 0) {
        Add-Issue $Issues $File ($headerIndex + 1) 1 $Rule "$Name must contain at least one list item."
        return
    }

    # Build the exact indentation prefix required by the settings above.
    $indent = if ($settings.indentStyle -eq 'tabs') { "`t" } else { ' ' * [int]$settings.indentSize }
    $indentDescription = if ($settings.indentStyle -eq 'tabs') { 'a tab' } else { "$($settings.indentSize) spaces" }
    for ($entryNumber = 0; $entryNumber -lt $entries.Count; $entryNumber++) {
        $lineIndex = $entries[$entryNumber]
        $line = $Lines[$lineIndex]
        if (-not $line.StartsWith($indent)) {
            Add-Issue $Issues $File ($lineIndex + 1) 1 $Rule "$Name list items must be indented with $indentDescription."
        }
        # A list uses commas between entries and a semicolon after its final entry.
        $trimmed = $line.Trim()
        $isLast = $entryNumber -eq ($entries.Count - 1)
        if ($isLast -and -not $trimmed.EndsWith(';')) {
            Add-Issue $Issues $File ($lineIndex + 1) ([Math]::Max(1, $line.Length)) $Rule "The final $Name item must end with ';'."
        }
        elseif (-not $isLast -and -not $trimmed.EndsWith(',')) {
            Add-Issue $Issues $File ($lineIndex + 1) ([Math]::Max(1, $line.Length)) $Rule "Non-final $Name items must end with ','."
        }
    }
}

# Parse and validate one complete circuit file. All errors are appended to Issues
# instead of stopping at the first problem, so VS Code can display everything at once.
function Test-MhrdContent {
    param(
        [string]$File,
        [string]$Content,
        [Collections.Generic.List[object]]$Issues
    )
    $lines = @(Get-ContentLines $Content)
    $sections = @('Inputs', 'Outputs', 'Parts', 'Wires')
    # Rule ranges identify which profile produced an error:
    # MHRD1xx = implemented circuit; MHRD2xx = interface specification.
    $rules = @{
        Inputs = 'MHRD101'
        Outputs = 'MHRD102'
        Parts = 'MHRD103'
        Wires = 'MHRD104'
    }
    $positions = @{}

    # First pass: locate each recognised section. Later checks can then validate
    # presence and ordering without repeatedly scanning the entire file.
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], '^\s*(Inputs|Outputs|Parts|Wires):')
        if ($match.Success) {
            $name = $match.Groups[1].Value
            if ($positions.ContainsKey($name)) {
                Add-Issue $Issues $File ($index + 1) 1 $rules[$name] "$name section may only appear once."
            }
            else {
                $positions[$name] = $index
            }
        }
    }

    # The presence of this header selects the interface-only rules. -1 means the
    # header was not found, so the normal implemented-circuit rules will be used.
    $interfaceHeaderIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq 'Interface Specification:') {
            $interfaceHeaderIndex = $index
            break
        }
    }
    $isInterfaceSpecification = [bool]$settings.allowInterfaceSpecifications -and $interfaceHeaderIndex -ge 0

    if ($isInterfaceSpecification) {
        # Interface profile layout:
        # Interface Specification:
        # ------------------------
        # Inputs: ...;
        # Outputs: ...;
        $firstContent = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$index])) { $firstContent = $index; break }
        }
        if ($interfaceHeaderIndex -ne $firstContent -or $lines[$interfaceHeaderIndex] -cne 'Interface Specification:') {
            Add-Issue $Issues $File ($interfaceHeaderIndex + 1) 1 'MHRD201' "Interface Specification: must be the first non-blank line and have no indentation."
        }

        $dividerIndex = $interfaceHeaderIndex + 1
        if ($dividerIndex -ge $lines.Count -or $lines[$dividerIndex] -cne [string]$settings.interfaceDivider) {
            Add-Issue $Issues $File ($interfaceHeaderIndex + 1) 1 'MHRD201' "Interface header must be followed by '$($settings.interfaceDivider)'."
        }

        foreach ($section in @('Inputs', 'Outputs')) {
            if (-not $positions.ContainsKey($section)) {
                $rule = if ($section -eq 'Inputs') { 'MHRD202' } else { 'MHRD203' }
                Add-Issue $Issues $File 1 1 $rule "Required $section section is missing from the interface specification."
            }
        }
        if ($positions.ContainsKey('Inputs') -and [int]$positions['Inputs'] -ne ($interfaceHeaderIndex + 2)) {
            Add-Issue $Issues $File ([int]$positions['Inputs'] + 1) 1 'MHRD202' 'Inputs must immediately follow the interface divider.'
        }
        if ($positions.ContainsKey('Inputs') -and $positions.ContainsKey('Outputs') -and
            [int]$positions['Outputs'] -ne ([int]$positions['Inputs'] + 1)) {
            Add-Issue $Issues $File ([int]$positions['Outputs'] + 1) 1 'MHRD203' 'Outputs must immediately follow Inputs.'
        }

        Test-InlineList $lines $positions 'Inputs' 'MHRD202' $File $Issues
        Test-InlineList $lines $positions 'Outputs' 'MHRD203' $File $Issues

        # An interface file declares a public shape only; implementation sections
        # belong in a normal circuit file.
        foreach ($section in @('Parts', 'Wires')) {
            if ($positions.ContainsKey($section)) {
                Add-Issue $Issues $File ([int]$positions[$section] + 1) 1 'MHRD204' "$section is not allowed in an interface-only specification."
            }
        }
        if ([bool]$settings.requireInterfaceOutputsLast -and $positions.ContainsKey('Outputs')) {
            $lastContent = -1
            for ($index = $lines.Count - 1; $index -ge 0; $index--) {
                if (-not [string]::IsNullOrWhiteSpace($lines[$index])) { $lastContent = $index; break }
            }
            if ([int]$positions['Outputs'] -ne $lastContent) {
                Add-Issue $Issues $File ([int]$positions['Outputs'] + 1) 1 'MHRD203' 'Outputs must be the final non-blank line in an interface specification.'
            }
        }
        # Do not run the normal four-section profile after this profile succeeds.
        return
    }

    # Normal circuit profile: all four sections must exist.
    foreach ($section in $sections) {
        if (-not $positions.ContainsKey($section) -and [bool]$settings.requireAllSections) {
            Add-Issue $Issues $File 1 1 $rules[$section] "Required $section section is missing."
        }
    }

    if ([bool]$settings.requireInputsAtTop -and $positions.ContainsKey('Inputs')) {
        $firstContent = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if (-not [string]::IsNullOrWhiteSpace($lines[$index])) { $firstContent = $index; break }
        }
        if ($firstContent -ne [int]$positions['Inputs']) {
            Add-Issue $Issues $File ([int]$positions['Inputs'] + 1) 1 'MHRD101' 'Inputs must be the first non-blank line in the file.'
        }
    }

    # Compare neighbouring sections to enforce Inputs -> Outputs -> Parts -> Wires.
    for ($index = 1; $index -lt $sections.Count; $index++) {
        $previous = $sections[$index - 1]
        $current = $sections[$index]
        if ($positions.ContainsKey($previous) -and $positions.ContainsKey($current) -and
            [int]$positions[$current] -lt [int]$positions[$previous]) {
            Add-Issue $Issues $File ([int]$positions[$current] + 1) 1 $rules[$current] "$current must appear after $previous."
        }
    }

    Test-InlineList $lines $positions 'Inputs' 'MHRD101' $File $Issues
    Test-InlineList $lines $positions 'Outputs' 'MHRD102' $File $Issues
    Test-IndentedList $lines $positions 'Parts' 'Wires' 'MHRD103' $File $Issues
    Test-IndentedList $lines $positions 'Wires' '' 'MHRD104' $File $Issues
}

# Discover extensionless circuit files, lint each one, and print the collected
# diagnostics. lastIssueCount is used below to choose the process exit code.
function Invoke-MhrdLint {
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($inputPath in $Path) {
        if (-not (Test-Path -LiteralPath $inputPath)) {
            [Console]::Error.WriteLine("Path not found: $inputPath")
            $script:lastIssueCount = -1
            return
        }
        $item = Get-Item -LiteralPath $inputPath
        if ($item.PSIsContainer) {
            # Only extensionless MHRD files are linted. Markdown theory notes and
            # every other file with an extension are ignored automatically.
            foreach ($file in Get-ChildItem -LiteralPath $item.FullName -File -Recurse) {
                $relative = Get-RelativeLintPath $file.FullName
                if (-not $file.Extension -and -not (Test-IgnoredLintPath $relative)) {
                    $files.Add($file)
                }
            }
        }
        elseif (-not $item.Extension) {
            $relative = Get-RelativeLintPath $item.FullName
            if (-not (Test-IgnoredLintPath $relative)) { $files.Add($item) }
        }
    }

    $issues = [Collections.Generic.List[object]]::new()
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        Test-MhrdContent (Get-RelativeLintPath $file.FullName) ([IO.File]::ReadAllText($file.FullName)) $issues
    }

    if ($Format -eq 'json') {
        ConvertTo-Json -InputObject @($issues) -Depth 4
    }
    else {
        # This exact format is parsed by the problem matcher in .vscode/tasks.json.
        foreach ($issue in $issues) {
            Write-Output "$($issue.file):$($issue.line):$($issue.column) $($issue.rule) $($issue.message)"
        }
        if ($issues.Count -eq 0) {
            Write-Output "MHRD lint passed ($($files.Count) file(s))."
        }
    }
    $script:lastIssueCount = $issues.Count
}

if ($Watch) {
    if ($Format -ne 'text') {
        [Console]::Error.WriteLine('Watch mode only supports text output.')
        exit 2
    }

    # FileSystemWatcher lets the VS Code background task sleep between saves rather
    # than repeatedly scanning the repository in a busy loop.
    $watchers = [Collections.Generic.List[IO.FileSystemWatcher]]::new()
    $subscriptions = [Collections.Generic.List[object]]::new()
    try {
        $watcherNumber = 0
        foreach ($inputPath in $Path) {
            if (-not (Test-Path -LiteralPath $inputPath)) { continue }
            $item = Get-Item -LiteralPath $inputPath
            $directory = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
            $watcher = [IO.FileSystemWatcher]::new($directory)
            $watcher.IncludeSubdirectories = $item.PSIsContainer
            $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
            $watcher.EnableRaisingEvents = $true
            $watchers.Add($watcher)

            # Any operation that can change the lint result wakes the watcher.
            foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
                $source = "MhrdLint.$watcherNumber.$eventName"
                $subscription = Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $source
                $subscriptions.Add($subscription)
            }
            $watcherNumber++
        }

        while ($true) {
            # These marker lines tell VS Code when one diagnostic collection cycle
            # starts and ends, allowing it to replace stale Problems entries.
            Write-Output 'MHRD lint cycle started.'
            Invoke-MhrdLint
            Write-Output 'MHRD lint cycle complete.'

            # Wait without consuming CPU. Editors sometimes emit several events for
            # one save, so the short debounce combines them into one lint cycle.
            do {
                $fileChangeEvent = Wait-Event
                Remove-Event -EventIdentifier $fileChangeEvent.EventIdentifier
                $changedPath = $fileChangeEvent.SourceEventArgs.FullPath
                $changedRelativePath = Get-RelativeLintPath $changedPath
                $isCircuitChange = -not [IO.Path]::GetExtension($changedPath) -and
                    -not (Test-IgnoredLintPath $changedRelativePath)
            } while (-not $isCircuitChange)
            Start-Sleep -Milliseconds $DebounceMilliseconds
            foreach ($pending in @(Get-Event)) {
                Remove-Event -EventIdentifier $pending.EventIdentifier
            }
        }
    }
    finally {
        # Release event registrations and OS file handles when VS Code stops the task.
        foreach ($subscription in $subscriptions) {
            Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
        }
        foreach ($watcher in $watchers) { $watcher.Dispose() }
    }
}

# One-shot mode is used by Ctrl+Shift+B and command-line runs. Exit code 1 means
# lint problems; exit code 2 means the requested path or invocation was invalid.
Invoke-MhrdLint
if ($script:lastIssueCount -lt 0) { exit 2 }
if ($script:lastIssueCount -gt 0) { exit 1 }
exit 0
