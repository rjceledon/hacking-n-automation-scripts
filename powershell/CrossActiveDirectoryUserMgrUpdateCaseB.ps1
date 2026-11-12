# rjceledon 11/12/2026

Import-Module ActiveDirectory

$CsvPath    = "C:\Temp\MismatchManagerForeignForest\contoso-users-mgr-mismatch.csv"
$ResultsCsv = "C:\Temp\MismatchManagerForeignForest\contoso-users-mgr-mismatch-RESULTS.csv"

$FabrikamDC = "fabrikam.com"
$ContosoDC  = "contoso.lan"

# Already created before running
$ContosoCred = Get-Credential -Message "Enter a Contoso Domain Admin" -UserName "CONTOSO\admin.user"

$FabrikamDN = (Get-ADDomain -Server $FabrikamDC).DistinguishedName

$Rows = @(Import-Csv $CsvPath)
$Results = @()

$Count = 0

foreach ($Row in $Rows) {

    $Count++

    $UserUPN = $Row.EmpEmail.Trim()
    $MgrUPN  = $Row.MgrUPN.Trim()

    $CurrentManager  = "NONE"
    $ReadableManager = ""
    $FspCN           = ""
    $Result          = ""

    Write-Progress `
        -Activity "Checking manager mappings" `
        -Status "$Count of $($Rows.Count) - $UserUPN" `
        -PercentComplete (($Count / $Rows.Count) * 100)

    try {

        # Find employee in Fabrikam
        $User = Get-ADUser `
            -Server $FabrikamDC `
            -Filter "UserPrincipalName -eq '$UserUPN'" `
            -Properties manager `
            -ErrorAction Stop

        if (-not $User) {
            throw "Employee not found"
        }

        if ($User.Manager) {
            $CurrentManager = $User.Manager
        }

        # Find manager in Contoso
        $Manager = Get-ADUser `
            -Server $ContosoDC `
            -Credential $ContosoCred `
            -Filter "mail -eq '$MgrUPN' -or UserPrincipalName -eq '$MgrUPN'" `
            -Properties SID `
            -ErrorAction Stop

        if (-not $Manager) {
            throw "Manager not found"
        }

        # Resolve readable CONTOSO\username
        try {
            $ReadableManager = $Manager.SID.Translate(
                [System.Security.Principal.NTAccount]
            ).Value
        }
        catch {
            $ReadableManager = $Manager.Name
        }

        # Build FSP DN in Fabrikam
        $ManagerSID = $Manager.SID.Value
        $FspDN = "CN=$ManagerSID,CN=ForeignSecurityPrincipals,$FabrikamDN"

        # Make sure the FSP exists
        $FSP = Get-ADObject `
            -Server $FabrikamDC `
            -Identity $FspDN `
            -ErrorAction Stop

        $FspCN = $FSP.Name

        # WhatIf only
        # 6>$null hides the normal "What if: Performing..." output
        Set-ADUser `
            -Server $FabrikamDC `
            -Identity $User `
            -Replace @{
                manager = $FSP.DistinguishedName
            } `
            #-WhatIf

        $Result = "WHATIF PASSED"

        Write-Host `
            "[+] Found foreign principal $ReadableManager for user $UserUPN - WhatIf PASSED" `
            -ForegroundColor Green
    }
    catch {

        $Result = "WHATIF FAILED: $($_.Exception.Message)"

        Write-Host `
            "[-] $UserUPN - WhatIf FAILED: $($_.Exception.Message)" `
            -ForegroundColor Red
    }

    $Results += [PSCustomObject]@{
        EmpEmail         = $UserUPN
        CurrentManager   = $CurrentManager
        RequestedManager = $MgrUPN
        ForeignPrincipal = $ReadableManager
        FspCN            = $FspCN
        Result           = $Result
    }
}

Write-Progress -Activity "Checking manager mappings" -Completed

# Export results
$Results | Export-Csv `
    -Path $ResultsCsv `
    -NoTypeInformation `
    -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host "FINAL RESULTS"
Write-Host "============================================================"

$Results |
    Select-Object EmpEmail, RequestedManager, ForeignPrincipal, Result |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Total:  $($Results.Count)"
Write-Host "Passed: $(($Results | Where-Object Result -eq 'WHATIF PASSED').Count)" `
    -ForegroundColor Green

Write-Host "Failed: $(($Results | Where-Object Result -like 'WHATIF FAILED*').Count)" `
    -ForegroundColor Red

Write-Host ""
Write-Host "Results saved to:"
Write-Host $ResultsCsv
