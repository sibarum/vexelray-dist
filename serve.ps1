<#
.SYNOPSIS
  Serves a folder at http://127.0.0.1:<Port>/, as GitHub serves the scripts, manifests and releases. For the local
  preflight (deploy.ps1 -Local writes local\); stops when its process is stopped.
#>
param([Parameter(Mandatory)][string]$Root, [int]$Port = 8417)
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://127.0.0.1:$Port/")
$l.Start()
while ($l.IsListening) {
    $c = $l.GetContext()
    $p = Join-Path $Root ([Uri]::UnescapeDataString($c.Request.Url.AbsolutePath).TrimStart('/').Replace('/', '\'))
    if ($p -notmatch '\\\.\.(\\|$)' -and (Test-Path -LiteralPath $p -PathType Leaf)) {
        $b = [IO.File]::ReadAllBytes($p)
        # GitHub's raw host serves scripts and manifests as text/plain
        if ($p -match '\.(ps1|json|md)$') { $c.Response.ContentType = 'text/plain; charset=utf-8' }
        else { $c.Response.ContentType = 'application/octet-stream' }
        $c.Response.ContentLength64 = $b.Length
        $c.Response.OutputStream.Write($b, 0, $b.Length)
    } else { $c.Response.StatusCode = 404 }
    $c.Response.Close()
}
