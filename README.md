# PsDownload

A PowerShell module for downloading files.
<br>

## Why?

- Invoke-WebRequest requires you to supply the output filename, which you might not know in advance, and it's not always possible to extract it from the URL.
- It will also hold the entire file in memory whilst downloading, which is bad news if downloading large files.
- Also the progress bar gets updated so frequently that it drastically slows down the download.
- Start-BitsTransfer can determine the file name automatically, but it does not work for all URLs and is only supported on Windows.
- Some URLs require different user agents connect successfully.

This module:

- Uses the .NET HttpClient class (which is now recommended for use by Microsoft over the now deprecated WebClient class).
- Will attempt to grab the file name from the Content-Disposition header. Headers are obtained by a regular GET request as not all web servers accept HEAD requests. If this header is not present, it will extract the file name from the absolute URL (since the supplied URL may redirect elsewhere).
- Streams directly to disk rather than hold the entire file in memory.
- Modified date will be updated once download has complete to match the Last-Modified header if found.
- Progress bar limited to updating every 250ms to prevent overuse of system resources.
<br>

## Installation

Install from the [Powershell Gallery](https://www.powershellgallery.com/packages/PsDownload) by running the following command:

```powershell
Install-Module -Name PsDownload
```
<br>

## Usage

```powershell
Invoke-Download -URL "https://aka.ms/vs/17/release/VC_redist.x64.exe" -Destination "$env:USERPROFILE\Downloads"
```

Pipeline input is also supported:

```powershell
"https://aka.ms/vs/17/release/VC_redist.x64.exe","https://aka.ms/vs/17/release/VC_redist.x86.exe" | Invoke-Download -Destination "$env:USERPROFILE\Downloads"
```

**URI** is also accepted as an alias of **URL**.
<br>

Optional parameters:

- FileName
  - Use this to override the file name rather than trying to auto-detect.
- UserAgent
  - Override the default user agents. By default it will cycle through using:
    - Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36
    - Googlebot/2.1 (+http://www.google.com/bot.html)
- TempPath
  - By default the download in progress will be saved to %TEMP% / $env:TEMP.
- IgnoreDate
  - Ignore the Date-Modified header, modified will be the date the file was downloaded instead.
- BlockFile
  - Mark the file as downloaded from the internet (by default it does not do this).
- NoClobber
  - Use this to prevent overwriting an existing file.
- NoProgress
  - Suppress progress bar.
- $PassThru
  - Returns a FileInfo object to the pipeline for the downloaded file.
<br>

## Issues

This has been tested against a large number of URLs, please submit an issue if it is unable to download a specific file. Note that some URLs load a page that runs some javascript to trigger the actual download. This type of URL is not supported, it must either point directly to the resource or the server will redirect the URL to the resource without the need to execute any client-side scripts.
