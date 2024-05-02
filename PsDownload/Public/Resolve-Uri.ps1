<#
.SYNOPSIS
Resolve-Uri resolves a URI and retrieves information such as file size, last modified date, and filename.

.DESCRIPTION
The Resolve-Uri function resolves the given URI and retrieves information such as file size, last modified date, and filename. It sends a GET request to the URL and retrieves the headers to extract the required information.

.PARAMETER Uri
The URI to resolve. This parameter is mandatory. URL is accepted as an alias.

.PARAMETER UserAgent
The user agent string to use for the request. By default, it uses two user agent strings: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36' and 'Googlebot/2.1 (+http://www.google.com/bot.html)'. You can specify multiple user agent strings as an array.

.PARAMETER Headers
Additional headers to include in the request. Default is @{'accept' = '*/*'}, which is needed to trick some servers into serving a download, such as from FileZilla.

.OUTPUTS
The function outputs a custom object with the following properties:
- Uri: The original URL.
- AbsoluteUri: The resolved URL after any redirections.
- FileName: The extracted filename from the URL or headers.
- FileSizeBytes: The file size in bytes.
- FileSizeReadable: The file size in a human-readable format.
- LastModified: The last modified date of the file.

.EXAMPLE
Resolve-Uri -Uri 'https://example.com/file.txt'
Resolves the URL 'https://example.com/file.txt' and retrieves the file information.

.EXAMPLE
Resolve-Uri -Uri 'https://example.com/file.txt' -UserAgent 'My User Agent'
Resolves the URL 'https://example.com/file.txt' using the specified user agent string.

.EXAMPLE
Resolve-Uri -Uri 'https://example.com/file.txt' -Headers @{ 'Authorization' = 'Bearer token' }
Resolves the URL 'https://example.com/file.txt' and includes the 'Authorization' header in the request.

#>
function Resolve-Uri {

    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [Alias('Url')]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [string[]]$UserAgent = @($null, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36', 'Googlebot/2.1 (+http://www.google.com/bot.html)'),
        
        [hashtable]$Headers = @{accept = '*/*' }
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

        if ($null -ne $Headers) {
            foreach ($Header in $Headers.GetEnumerator()) {
                $HttpClient.DefaultRequestHeaders.Add($Header.Key, $Header.Value)
            }
        }

    }

    process {

        # Reset variables
        $FileName = $AbsoluteUri = $FileSizeBytes = $FileSizeReadable = $LastModified = $null

        Write-Verbose "$($MyInvocation.MyCommand): Requesting headers from URL '$Uri'"

        foreach ($UserAgentString in $UserAgent) {
            $HttpClient.DefaultRequestHeaders.Remove('User-Agent') | Out-Null
            if ($UserAgentString) {
                Write-Verbose "$($MyInvocation.MyCommand): Using UserAgent '$UserAgentString'"
                $HttpClient.DefaultRequestHeaders.Add('User-Agent', $UserAgentString)
            }

            # This sends a GET request but only retrieves the headers
            $ResponseHeader = $HttpClient.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result

            # Exit the foreach if success
            if ($ResponseHeader.IsSuccessStatusCode) {
                break
            }
        }

        if ($ResponseHeader.IsSuccessStatusCode) {
            Write-Verbose "$($MyInvocation.MyCommand): Successfully retrieved headers"

            if ($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri -ne $Uri) {
                Write-Verbose "$($MyInvocation.MyCommand): URL '$Uri' redirects to '$($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri)'"
            }

            try {
                $FileSizeBytes = $null
                $FileSizeBytes = [int]$ResponseHeader.Content.Headers.GetValues('Content-Length')[0]
                $FileSizeReadable = switch ($FileSizeBytes) {
                    { $_ -gt 1TB } { '{0:n2} TB' -f ($_ / 1TB); Break }
                    { $_ -gt 1GB } { '{0:n2} GB' -f ($_ / 1GB); Break }
                    { $_ -gt 1MB } { '{0:n2} MB' -f ($_ / 1MB); Break }
                    { $_ -gt 1KB } { '{0:n2} KB' -f ($_ / 1KB); Break }
                    default { '{0} B' -f $_ }
                }
                Write-Verbose "$($MyInvocation.MyCommand): File size: $FileSizeBytes bytes ($FileSizeReadable)"
            }
            catch {
                Write-Verbose "$($MyInvocation.MyCommand): Unable to determine file size"
            }

            # Try to get the last modified date from the "Last-Modified" header, use error handling in case string is in invalid format
            try {
                $LastModified = $null
                $LastModified = [DateTime]::ParseExact($ResponseHeader.Content.Headers.GetValues('Last-Modified')[0], 'r', [System.Globalization.CultureInfo]::InvariantCulture)
                Write-Verbose "$($MyInvocation.MyCommand): Last modified: $($LastModified.ToString())"
            }
            catch {
                Write-Verbose "$($MyInvocation.MyCommand): Last-Modified header not found"
            }

            if ($FileName) {
                $FileName = $FileName.Trim()
                Write-Verbose "$($MyInvocation.MyCommand): Will use supplied filename '$FileName'"
            }
            else {
                # Get the file name from the "Content-Disposition" header if available
                try {
                    $ContentDispositionHeader = $null
                    $ContentDispositionHeader = $ResponseHeader.Content.Headers.GetValues('Content-Disposition')[0]
                    Write-Verbose "$($MyInvocation.MyCommand): Content-Disposition header found: $ContentDispositionHeader"
                }
                catch {
                    Write-Verbose "$($MyInvocation.MyCommand): Content-Disposition header not found"
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
                        Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from Content-Disposition header"
                    }
                    else {
                        Write-Verbose "$($MyInvocation.MyCommand): Failed to extract filename from Content-Disposition header"
                    }
                }
    
                if ([string]::IsNullOrEmpty($FileName)) {
                    # If failed to parse Content-Disposition header or if it's not available, extract the file name from the absolute URL to capture any redirections.
                    # GetFileName ensures we are not getting a full path with slashes. UrlDecode will convert characters like %20 back to spaces. The URL is split with ? to ensure we can strip off any API parameters.
                    $FileName = [System.IO.Path]::GetFileName([System.Web.HttpUtility]::UrlDecode($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri.Split('?')[0]))
                    [IO.Path]::GetinvalidFileNameChars() | ForEach-Object { $FileName = $FileName.Replace($_, ' ') }
                    $FileName = $FileName.Trim()
                    Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from absolute URL '$($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri)'"
                }
            }

        }
        else {
            throw "$($MyInvocation.MyCommand): Failed to retrieve headers from $($Uri): $([int]$ResponseHeader.StatusCode): $($ResponseHeader.ReasonPhrase)"
        }

        if ([string]::IsNullOrEmpty($FileName)) {
            # If still no filename set, extract the file name from the original URL.
            # GetFileName ensures we are not getting a full path with slashes. UrlDecode will convert characters like %20 back to spaces. The URL is split with ? to ensure we can strip off any API parameters.
            $FileName = [System.IO.Path]::GetFileName([System.Web.HttpUtility]::UrlDecode($Uri.Split('?')[0]))
            [System.IO.Path]::GetInvalidFileNameChars() | ForEach-Object { $FileName = $FileName.Replace($_, ' ') }
            $FileName = $FileName.Trim()
            Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from original URL '$Uri'"
        }

        [PSCustomObject]@{
            Uri              = $Uri
            AbsoluteUri      = $ResponseHeader.RequestMessage.RequestUri.AbsoluteUri
            FileName         = $FileName
            FileSizeBytes    = $FileSizeBytes
            FileSizeReadable = $FileSizeReadable
            LastModified     = $LastModified
        }

    }

    end {
        $HttpClient.Dispose()
    }
}