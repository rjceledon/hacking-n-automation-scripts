# rjceledon 11/12/2026

Import-Module ActiveDirectory

$CsvPath    = "C:\Temp\MismatchManagerForeignForest\special-cases-mgr-mismatch.csv"
$ResultsCsv = "C:\Temp\MismatchManagerForeignForest\special-cases-mgr-mismatch-RESULTS.csv"

$ContosoDC  = "contoso.lan"
$FabrikamDC = "fabrikam.com"

$ContosoCred = Get-Credential `
    -Message "Enter a Contoso Domain Admin" `
    -UserName "CONTOSO\celedonr"

$ContosoDN = (Get-ADDomain `
    -Server $ContosoDC `
    -Credential $ContosoCred
).DistinguishedName

$Rows = @(Import-Csv $CsvPath)
$Results = @()

$Count = 0

foreach ($Row in $Rows) {

    $Count++

    $EmpUPN = $Row.EmpUPN.Trim()
    $MgrUPN = $Row.MgrUPN.Trim()

    $ReadableManager = ""
    $FspCN = ""
    $Result = ""

    Write-Progress `
        -Activity "Checking special manager cases" `
        -Status "$Count of $($Rows.Count) - $EmpUPN" `
        -PercentComplete (($Count / $Rows.Count) * 100)

    try {

        if ([string]::IsNullOrWhiteSpace($EmpUPN)) {
            throw "EmpUPN is empty"
        }

        if ([string]::IsNullOrWhiteSpace($MgrUPN)) {
            throw "MgrUPN is empty"
        }

        # Find employee in Contoso
        $User = Get-ADUser `
            -Server $ContosoDC `
            -Credential $ContosoCred `
            -Filter "mail -eq '$EmpUPN' -or UserPrincipalName -eq '$EmpUPN'" `
            -Properties manager `
            -ErrorAction Stop

        if (-not $User) {
            throw "Employee not found in Contoso"
        }

        # Find manager in Fabrikam
        $Manager = Get-ADUser `
            -Server $FabrikamDC `
            -Filter "mail -eq '$MgrUPN' -or UserPrincipalName -eq '$MgrUPN'" `
            -Properties SID `
            -ErrorAction Stop

        if (-not $Manager) {
            throw "Manager not found in Fabrikam"
        }

        $ManagerSID = $Manager.SID.Value

        try {
            $ReadableManager = $Manager.SID.Translate(
                [System.Security.Principal.NTAccount]
            ).Value
        }
        catch {
            $ReadableManager = $Manager.Name
        }

        # Make sure FSP exists in Contoso
        $FSP = Get-ADObject `
            -Server $ContosoDC `
            -Credential $ContosoCred `
            -SearchBase "CN=ForeignSecurityPrincipals,$ContosoDN" `
            -Filter "Name -eq '$ManagerSID'" `
            -ErrorAction Stop

        if (-not $FSP) {
            throw "FSP not found in Contoso for $ReadableManager"
        }

        $FspCN = $FSP.Name

        # Test only - no change made
        Set-ADUser `
            -Server $ContosoDC `
            -Credential $ContosoCred `
            -Identity $User `
            -Replace @{
                manager = $FSP.DistinguishedName
            } `
            -WhatIf `
            -ErrorAction Stop 6>$null

        $Result = "WHATIF PASSED"

        Write-Host `
            "[+] Found foreign principal $ReadableManager for $EmpUPN - WhatIf PASSED" `
            -ForegroundColor Green
    }
    catch {

        $Result = "WHATIF FAILED: $($_.Exception.Message)"

        Write-Host `
            "[-] $EmpUPN - $Result" `
            -ForegroundColor Red
    }

    $Results += [PSCustomObject]@{
        EmpUPN           = $EmpUPN
        MgrUPN           = $MgrUPN
        ForeignPrincipal = $ReadableManager
        FspCN            = $FspCN
        Result           = $Result
    }
}

Write-Progress -Activity "Checking special manager cases" -Completed

$Results | Export-Csv `
    -Path $ResultsCsv `
    -NoTypeInformation `
    -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host "FINAL RESULTS"
Write-Host "============================================================"

$Results |
    Select-Object EmpUPN, MgrUPN, ForeignPrincipal, Result |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Total:  $($Results.Count)"
Write-Host "Passed: $(($Results | Where-Object Result -eq 'WHATIF PASSED').Count)" -ForegroundColor Green
Write-Host "Failed: $(($Results | Where-Object Result -like 'WHATIF FAILED*').Count)" -ForegroundColor Red
Write-Host ""
Write-Host "Results saved to:"
Write-Host $ResultsCsv
