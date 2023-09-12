function Invoke-Download {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [Alias('URI')]
        [ValidateNotNullOrEmpty()]
        [string]$URL,
        
        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination = $PWD.Path,
        
        [Parameter(Position = 2)]
        [string]$FileName,

        [string[]]$UserAgent = @('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36', 'Googlebot/2.1 (+http://www.google.com/bot.html)'),

        [string]$TempPath = [System.IO.Path]::GetTempPath(),

        [switch]$IgnoreDate,
        [switch]$BlockFile,
        [switch]$NoClobber,
        [switch]$NoProgress,
        [switch]$PassThru
    )	
	
    begin {
        # Required on Windows Powershell only
        if ($PSEdition -eq 'Desktop') {
            Add-Type -AssemblyName System.Net.Http
            Add-Type -AssemblyName System.Web
        }

        # Enable TLS 1.2 in addition to whatever is pre-configured
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # Create one single client object for the pipeline
        $HttpClient = New-Object System.Net.Http.HttpClient
    }

    process {

        Write-Verbose "Requesting headers from URL '$URL'"

        foreach ($UserAgentString in $UserAgent) {
            $HttpClient.DefaultRequestHeaders.Remove('User-Agent') | Out-Null
            if ($UserAgentString) {
                Write-Verbose "Using UserAgent '$UserAgentString'"
                $HttpClient.DefaultRequestHeaders.Add('User-Agent', $UserAgentString)
            }

            # This sends a GET request but only retrieves the headers
            $ResponseHeader = $HttpClient.GetAsync($URL, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result

            # Exit the foreach if success
            if ($ResponseHeader.IsSuccessStatusCode) {
                break
            }
        }

        if ($ResponseHeader.IsSuccessStatusCode) {
            Write-Verbose 'Successfully retrieved headers'

            if ($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri -ne $URL) {
                Write-Verbose "URL '$URL' redirects to '$($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri)'"
            }

            try {
                $FileSize = $null
                $FileSize = [int]$ResponseHeader.Content.Headers.GetValues('Content-Length')[0]
                $FileSizeReadable = switch ($FileSize) {
                    { $_ -gt 1TB } { '{0:n2} TB' -f ($_ / 1TB); Break }
                    { $_ -gt 1GB } { '{0:n2} GB' -f ($_ / 1GB); Break }
                    { $_ -gt 1MB } { '{0:n2} MB' -f ($_ / 1MB); Break }
                    { $_ -gt 1KB } { '{0:n2} KB' -f ($_ / 1KB); Break }
                    default { '{0} B' -f $_ }
                }
                Write-Verbose "File size: $FileSize bytes ($FileSizeReadable)"
            }
            catch {
                Write-Verbose 'Unable to determine file size'
            }

            # Try to get the last modified date from the "Last-Modified" header, use error handling in case string is in invalid format
            try {
                $LastModified = $null
                $LastModified = [DateTime]::ParseExact($ResponseHeader.Content.Headers.GetValues('Last-Modified')[0], 'r', [System.Globalization.CultureInfo]::InvariantCulture)
                Write-Verbose "Last modified: $($LastModified.ToString())"
            }
            catch {
                Write-Verbose 'Last-Modified header not found'
            }

            if ($FileName) {
                $FileName = $FileName.Trim()
                Write-Verbose "Will use supplied filename '$FileName'"
            }
            else {
                # Get the file name from the "Content-Disposition" header if available
                try {
                    $ContentDispositionHeader = $null
                    $ContentDispositionHeader = $ResponseHeader.Content.Headers.GetValues('Content-Disposition')[0]
                    Write-Verbose "Content-Disposition header found: $ContentDispositionHeader"
                }
                catch {
                    Write-Verbose 'Content-Disposition header not found'
                }
                if ($ContentDispositionHeader) {
                    $ContentDispositionRegEx = @'
^.*filename\*?\s*=\s*"?(?:UTF-8|iso-8859-1)?(?:'[^']*?')?([^";]+)
'@
                    if ($ContentDispositionHeader -match $ContentDispositionRegEx) {
                        # GetFileName ensures we are not getting a full path with slashes. UrlDecode will convert characters like %20 back to spaces.
                        $FileName = [System.IO.Path]::GetFileName([System.Web.HttpUtility]::UrlDecode($matches[1]))
                        # If any further invalid filename characters are found, convert them to spaces.
                        [IO.Path]::GetinvalidFileNameChars() | ForEach-Object { $FileName = $FileName.Replace($_, ' ') }
                        $FileName = $FileName.Trim()
                        Write-Verbose "Extracted filename '$FileName' from Content-Disposition header"
                    }
                    else {
                        Write-Verbose 'Failed to extract filename from Content-Disposition header'
                    }
                }
    
                if ([string]::IsNullOrEmpty($FileName)) {
                    # If failed to parse Content-Disposition header or if it's not available, extract the file name from the absolute URL to capture any redirections.
                    # GetFileName ensures we are not getting a full path with slashes. UrlDecode will convert characters like %20 back to spaces. The URL is split with ? to ensure we can strip off any API parameters.
                    $FileName = [System.IO.Path]::GetFileName([System.Web.HttpUtility]::UrlDecode($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri.Split('?')[0]))
                    [IO.Path]::GetinvalidFileNameChars() | ForEach-Object { $FileName = $FileName.Replace($_, ' ') }
                    $FileName = $FileName.Trim()
                    Write-Verbose "Extracted filename '$FileName' from absolute URL '$($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri)'"
                }
            }

        }
        else {
            Write-Verbose 'Failed to retrieve headers'
        }

        if ([string]::IsNullOrEmpty($FileName)) {
            # If still no filename set, extract the file name from the original URL.
            # GetFileName ensures we are not getting a full path with slashes. UrlDecode will convert characters like %20 back to spaces. The URL is split with ? to ensure we can strip off any API parameters.
            $FileName = [System.IO.Path]::GetFileName([System.Web.HttpUtility]::UrlDecode($URL.Split('?')[0]))
            [System.IO.Path]::GetInvalidFileNameChars() | ForEach-Object { $FileName = $FileName.Replace($_, ' ') }
            $FileName = $FileName.Trim()
            Write-Verbose "Extracted filename '$FileName' from original URL '$URL'"
        }

        $DestinationFilePath = Join-Path $Destination $FileName

        # Exit if -NoClobber specified and file exists.
        if ($NoClobber -and (Test-Path -LiteralPath $DestinationFilePath -PathType Leaf)) {
            Write-Error 'NoClobber switch specified and file already exists'
            return
        }

        # Open the HTTP stream
        $ResponseStream = $HttpClient.GetStreamAsync($URL).Result

        if ($ResponseStream.CanRead) {

            # Check TempPath exists and create it if not
            if (-not (Test-Path -LiteralPath $TempPath -PathType Container)) {
                Write-Verbose "Temp folder '$TempPath' does not exist"
                try {
                    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
                    Write-Verbose "Created temp folder '$TempPath'"
                }
                catch {
                    Write-Error "Unable to create temp folder '$TempPath': $_"
                    return
                }
            }

            # Generate temp file name
            $TempFileName = (New-Guid).ToString('N') + ".tmp"
            $TempFilePath = Join-Path $TempPath $TempFileName

            # Check Destiation exists and create it if not
            if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
                Write-Verbose "Output folder '$Destination' does not exist"
                try {
                    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
                    Write-Verbose "Created output folder '$Destination'"
                }
                catch {
                    Write-Error "Unable to create output folder '$Destination': $_"
                    return
                }
            }

            # Open file stream
            try {
                $FileStream = [System.IO.File]::Create($TempFilePath)
            }
            catch {
                Write-Error "Unable to create file '$TempFilePath': $_"
                return
            }
        
            if ($FileStream.CanWrite) {
                Write-Verbose "Downloading to temp file '$TempFilePath'..."

                $Buffer = New-Object byte[] 16KB
                $BytesDownloaded = 0
                $ProgressTimer = Get-Date
                $ProgressIntervalMs = 250

                while ($true) {
                    try {
                        # Read stream into buffer
                        $ReadBytes = $ResponseStream.Read($Buffer, 0, $Buffer.Length)

                        # Track bytes downloaded for progress bar
                        $BytesDownloaded += $ReadBytes
                        if (!$NoProgress -and (Get-Date) -gt $ProgressTimer.AddMilliseconds($ProgressIntervalMs)) {
                            Write-Progress -Activity 'Downloading File' -Status $FileName -PercentComplete ($BytesDownloaded / $FileSize * 100)
                            $ProgressTimer = Get-Date
                        }

                        # If end of stream
                        if ($ReadBytes -eq 0) {
                            $FileStream.Close()
                            $FileStream.Dispose()
                            try {
                                Write-Verbose "Moving temp file to destination '$DestinationFilePath'"
                                $DownloadedFile = Move-Item -LiteralPath $TempFilePath -Destination $DestinationFilePath -Force -PassThru
                            }
                            catch {
                                Write-Error "Error moving file from '$TempFilePath' to '$DestinationFilePath': $_"
                                return
                            }
                            if ($IsWindows) {
                                if ($BlockFile) {
                                    Write-Verbose 'Marking file as downloaded from the internet'
                                    Set-Content -LiteralPath $DownloadedFile -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`nZoneId=3"
                                }
				else {
                                    Unblock-File -LiteralPath $DownloadedFile
                                }
                            }
                            if ($LastModified -and -not $IgnoreDate) {
                                Write-Verbose 'Setting Last Modified date'
                                $DownloadedFile.LastWriteTime = $LastModified
                            }
                            Write-Verbose 'Download complete!'
                            if ($PassThru) {
                                $DownloadedFile
                            }
                            break
                        }
                        $FileStream.Write($Buffer, 0, $ReadBytes)
                    }
                    catch {
                        Write-Error "Error downloading file: $_"
                        $FileStream.Close()
                        $FileStream.Dispose()
                        break
                    }
                }
    
            }
        }
        else {
            Write-Error 'Failed to start download'
        }

        # Reset this to avoid reusing the same name when fed multiple URLs via the pipeline
        $FileName = $null
    }

    end {
        $HttpClient.Dispose()
    }
}