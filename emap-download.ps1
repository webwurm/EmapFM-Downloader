# Step 0: Check for PowerShell version
$requiredVersion = [version]"7.0.0"
$currentVersion = $PSVersionTable.PSVersion

if ($currentVersion -lt $requiredVersion) {
    Write-Output "This script requires PowerShell 7.0 or above."
    Write-Output "You are currently running PowerShell $currentVersion."
    Write-Output "Please upgrade to PowerShell 7.0 or later to run this script."
    exit 1
}

# Step 1: Check for and delete .aac, .m3u8 files, and specific temporary files
$temporaryFiles = @("file.txt", "chunks.txt", "mylist.txt", "output.aac")
$existingAacFiles = Get-ChildItem -Path (Get-Location) -Filter "*.aac"
$existingM3u8Files = Get-ChildItem -Path (Get-Location) -Filter "*.m3u8"

# Collect all files to be deleted
$allFilesToDelete = $existingAacFiles, $existingM3u8Files, $temporaryFiles | Sort-Object Name

if ($allFilesToDelete.Count -gt 0) {

    $userResponse = Read-Host "Do you want to delete temp files? (Y/N)"
    if ($userResponse -eq "Y" -or $userResponse -eq "y") {
        foreach ($file in $allFilesToDelete) {
            if (Test-Path $file) {
                Remove-Item $file -Force
            }
        }
        Write-Output "All temp files have been deleted."
    } else {
        Write-Output "Files were not deleted. Exiting script to prevent conflicts."
        exit 1
    }
}

# Step 2: Get the URL of the homepage from user input
$homepageUrl = Read-Host "Enter the concert URL"
Write-Output "Concert URL: $homepageUrl"

# Step 3: Get the link from the homepage
try {
    # Attempt to get the HTML content from the URL
    $response = Invoke-WebRequest -Uri $homepageUrl -UseBasicParsing -Method Get
    $homepageContent = $response.Content
    Write-Output "Homepage content fetched successfully."
} catch {
    Write-Output "Failed to fetch homepage content. Error: $_"
    exit 1
}

# Debug output: Display the first 1000 characters of the homepage content
Write-Output "First 1000 characters of homepage content:"
$homepageContent.Substring(0, [Math]::Min(1000, $homepageContent.Length)) | Write-Output

# Parse the HTML to find the 'audiourl' attribute from the <li> tag
$audiourlPattern = 'audiourl=["'']([^"'']+)["'']'
$audiourlMatch = [regex]::Match($homepageContent, $audiourlPattern)

if ($audiourlMatch.Success) {
    $audiourl = $audiourlMatch.Groups[1].Value
    Write-Output "Audio URL: $audiourl"
} else {
    Write-Output "Failed to find the 'audiourl' attribute in the homepage content. Exiting script."
    exit 1
}

# Extract the base URL (everything up to the last "/")
$baseUrl = $audiourl.Substring(0, $audiourl.LastIndexOf("/") + 1)
Write-Output "Base URL: $baseUrl"

# Step 4: Download the text file from the audiourl
$localTextFilePath = Join-Path -Path (Get-Location) -ChildPath "file.txt"
try {
    Invoke-WebRequest -Uri $audiourl -OutFile $localTextFilePath
    Write-Output "Text file downloaded to: $localTextFilePath"
} catch {
    Write-Output "Failed to download the text file from audiourl. Exiting script."
    exit 1
}

# Step 5: Get the filename from the last line of the text file
try {
    $lines = Get-Content -Path $localTextFilePath
    $lastLine = $lines[-1].Trim()
    Write-Output "Last line (filename): $lastLine"
} catch {
    Write-Output "Failed to read the text file. Exiting script."
    exit 1
}

# Construct the new file URL by combining the base URL with the filename
$newFileUrl = $baseUrl + $lastLine
Write-Output "New file URL: $newFileUrl"

# Step 6: Download the new file
$localNewFilePath = Join-Path -Path (Get-Location) -ChildPath $lastLine
try {
    Invoke-WebRequest -Uri $newFileUrl -OutFile $localNewFilePath
    Write-Output "New file downloaded to: $localNewFilePath"
} catch {
    Write-Output "Failed to download the new file. Exiting script."
    exit 1
}

# Step 7: Process the new file to add base URL to each chunk filename
$chunkListPath = Join-Path -Path (Get-Location) -ChildPath "chunks.txt"
try {
    $chunkLines = Get-Content -Path $localNewFilePath | Where-Object { $_ -match "\.aac$" } | ForEach-Object { $baseUrl + $_ }
    $chunkLines | Set-Content -Path $chunkListPath
    Write-Output "Chunk list created at: $chunkListPath"
} catch {
    Write-Output "Failed to process the new file. Exiting script."
    exit 1
}

# Debug output: Display chunk list content
Write-Output "Chunk list content:"
Get-Content -Path $chunkListPath | ForEach-Object { Write-Output $_ }

# Step 8: Use PowerShell to download files and create mylist.txt simultaneously
$myListFilePath = Join-Path -Path (Get-Location) -ChildPath "mylist.txt"
$downloadCommand = @"
`$chunkUrls = Get-Content '$chunkListPath'
`$totalChunks = `$chunkUrls.Count
`$currentChunk = 0
foreach (`$url in `$chunkUrls) {
    `$currentChunk++
    `$outFile = Split-Path -Leaf `$url
    Write-Progress -Activity 'Downloading chunks' -Status "Downloading `$currentChunk of `$totalChunks" -PercentComplete ((`$currentChunk / `$totalChunks) * 100)
    Invoke-WebRequest -Uri `$url -OutFile `$outFile -SkipCertificateCheck
    Add-Content -Path '$myListFilePath' -Value "file '`$outFile'"
}
Write-Progress -Activity 'Downloading chunks' -Completed
"@
Write-Output "Executing download command:"
Write-Output $downloadCommand

try {
    # Execute download command
    Invoke-Expression $downloadCommand
    Write-Output "Chunks downloaded and mylist.txt created."
} catch {
    Write-Output "Failed to download chunks or create mylist.txt. Error: $_"
    exit 1
}

# Debug output: Display mylist.txt content
Write-Output "mylist.txt content:"
Get-Content -Path $myListFilePath | ForEach-Object { Write-Output $_ }

# Function to run ffmpeg command
function Run-Ffmpeg {
    param (
        [string]$Arguments
    )
    
    $ffmpegPath = "ffmpeg"  # Default to expecting ffmpeg in PATH
    
    # Check if ffmpeg is in the current directory
    if (Test-Path ".\ffmpeg.exe") {
        $ffmpegPath = ".\ffmpeg.exe"
    }
    
    # If ffmpeg is not found, ask user for the path
    if (-not (Get-Command $ffmpegPath -ErrorAction SilentlyContinue)) {
        $ffmpegPath = Read-Host "ffmpeg not found. Please enter the full path to ffmpeg.exe"
        if (-not (Test-Path $ffmpegPath)) {
            throw "Invalid ffmpeg path provided."
        }
    }
    
    # Run ffmpeg command
    $process = Start-Process -FilePath $ffmpegPath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "ffmpeg command failed with exit code $($process.ExitCode)"
    }
}

# Step 9: Combine files with ffmpeg
try {
    Run-Ffmpeg "-f concat -safe 0 -i `"$myListFilePath`" -c copy output.aac"
    Write-Output "Chunks combined into output.aac."
} catch {
    Write-Output "Failed to combine chunks with ffmpeg. Error: $_"
    exit 1
}

# Step 10: Convert the combined file to mp3
try {
    Run-Ffmpeg "-i `"output.aac`" -codec:a libmp3lame -q:a 2 `"output.mp3`""
    Write-Output "output.aac converted to output.mp3."
} catch {
    Write-Output "Failed to convert output.aac to output.mp3 with ffmpeg. Error: $_"
    exit 1
}

Write-Output "Convert downloaded successfully."

# Step 11 (again): Check for and delete .aac, .m3u8 files, and specific temporary files
$temporaryFiles = @("file.txt", "chunks.txt", "mylist.txt")
$existingAacFiles = Get-ChildItem -Path (Get-Location) -Filter "*.aac"
$existingM3u8Files = Get-ChildItem -Path (Get-Location) -Filter "*.m3u8"

# Collect all files to be deleted
$allFilesToDelete = $existingAacFiles, $existingM3u8Files, $temporaryFiles | Sort-Object Name

if ($allFilesToDelete.Count -gt 0) {

    $userResponse = Read-Host "Do you want to delete temp files? (Y/N)"
    if ($userResponse -eq "Y" -or $userResponse -eq "y") {
        foreach ($file in $allFilesToDelete) {
            if (Test-Path $file) {
                Remove-Item $file -Force
            }
        }
        Write-Output "All temp files have been deleted."
    } else {
        Write-Output "Files were not deleted."
        exit 1
    }
}