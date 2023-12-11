# For quickly dot-sourcing all functions into current session for testing

$Public = @(Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, '..\PsDownload\Public', '*.ps1')))
$Private = @(Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, '..\PsDownload\Private', '*.ps1')) -ErrorAction Ignore)

ForEach ($Import in @($Public + $Private)) {
    Try {
        . $Import.FullName
    }
    Catch {
        Write-Error -Message "Failed to import function $($Import.FullName): $_"
    }
}