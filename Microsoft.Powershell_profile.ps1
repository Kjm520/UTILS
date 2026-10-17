# SYMLINKED

# Aliases

#Funcations
function pingsweep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$subnet
    )

    1..254 | ForEach-Object {
        $ip = "192.168.$subnet.$_"
        if (ping.exe -n 1 -w 250 $ip | Select-String "TTL=") {
            $ip
        }
    }
}


function hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$path,
        [Parameter(Mandatory = $true)]
        [long]$offset,
        [Parameter(Mandatory = $true)]
        [int]$count
    )
    Format-Hex $path -Offset $offset -Count $count
}








