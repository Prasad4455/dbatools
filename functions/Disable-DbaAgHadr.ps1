#ValidationTags#Messaging,FlowControl,Pipeline,CodeStyle#
function Disable-DbaAgHadr {
    <#
        .SYNOPSIS
            Disables the Hadr service setting on the specified SQL Server.

        .DESCRIPTION
            In order to build an AG a cluster has to be built and then the Hadr enabled for the SQL Server
            service. This function disables that feature for the SQL Server service.

        .PARAMETER SqlInstance
            The SQL Server that you're connecting to.

        .PARAMETER Credential
            Credential object used to connect to the Windows server itself as a different user

        .PARAMETER WhatIf
            Shows what would happen if the command were to run. No actions are actually performed.

        .PARAMETER Confirm
            Prompts you for confirmation before executing any changing operations within the command.

        .PARAMETER Force
            Will restart SQL Server and SQL Server Agent service to apply the change.

        .PARAMETER EnableException
            By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
            This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
            Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

        .NOTES
            Tags: Hadr, AG, AvailabilityGroup
            Author: Shawn Melton (@wsmelton | http://blog.wsmelton.info)

            Website: https://dbatools.io
            Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
            License: MIT https://opensource.org/licenses/MIT

        .LINK
            https://dbatools.io/Disable-DbaAgHadr

        .EXAMPLE
            Disable-DbaAgHadr -SqlInstance sql2016 -Force

            Sets Hadr service to disabled for the instance sql2016, and restart the service to apply the change.

        .EXAMPLE
            Disable-DbaAgHadr -SqlInstance sql2012\dev1 -Force

            Sets Hadr service to disabled for the instance dev1 on sq2012, and restart the service to apply the change.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
    param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Alias("ServerInstance", "SqlServer")]
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$Credential,
        [switch]$Force,
        [Alias('Silent')]
        [switch]$EnableException
    )
    begin {
        function GetDbaAgHadr {
            [CmdletBinding()]
            param (
                [parameter(Mandatory = $true, ValueFromPipeline = $true)]
                [Alias("ServerInstance", "SqlServer")]
                [DbaInstanceParameter[]]$SqlInstance,
                [PSCredential]$Credential,
                [Alias('Silent')]
                [switch]$EnableException
            )
            process {
                foreach ($instance in $SqlInstance) {

                    try {
                        $computer = $computerName = $instance.ComputerName
                        $instanceName = $instance.InstanceName
                        Write-Message -Level Verbose -Message "Connecting to $computer"
                        $currentState = Invoke-ManagedComputerCommand -ComputerName $computerName -ScriptBlock { $wmi.Services[$args[0]] | Select-Object IsHadrEnabled } -ArgumentList $instanceName -Credential $Credential
                    }
                    catch {
                        Stop-Function -Message "Failure connecting to $computer" -Category ConnectionError -ErrorRecord $_ -Target $instance
                        return
                    }

                    if ($null -eq $currentState.IsHadrEnabled) {
                        $isenabled = $false
                    }
                    else {
                        $isenabled = $currentState.IsHadrEnabled
                    }
                    [PSCustomObject]@{
                        ComputerName     = $computer
                        InstanceName     = $instanceName
                        SqlInstance      = $instance.FullName
                        IsHadrEnabled    = $isenabled
                    }
                }
            }
        }
    }

    process {
        foreach ($instance in $SqlInstance) {
            $computer = $computerFullName = $instance.ComputerName
            $instanceName = $instance.InstanceName
            if (-not (Test-ElevationRequirement -ComputerName $instance)) {
                return
            }
            $noChange = $false

            switch ($instance.InstanceName) {
                'MSSQLSERVER' { $agentName = 'SQLSERVERAGENT' }
                default { $agentName = "SQLAgent`$$instanceName" }
            }

            try {
                Write-Message -Level Verbose -Message "Checking current Hadr setting for $computer"
                $currentState = GetDbaAgHadr -SqlInstance $instance -Credential $Credential
            }
            catch {
                Stop-Function -Message "Failure to pull current state of Hadr setting on $computer" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            $isHadrEnabled = $currentState.IsHadrEnabled
            Write-Message -Level InternalComment -Message "$instance Hadr current value: $isHadrEnabled"

            # hadr results from sql wmi can be iffy, skip the check
            <#
            if (-not $isHadrEnabled) {
                Write-Message -Level Warning -Message "Hadr is already disabled for instance: $($instance.FullName)"
                $noChange = $true
                continue
            }
            #>

            $scriptblock = {
                $instance = $args[0]
                $sqlService = $wmi.Services | Where-Object DisplayName -eq "SQL Server ($instance)"
                $sqlService.ChangeHadrServiceSetting(0)
            }

            if ($noChange -eq $false) {
                if ($PSCmdlet.ShouldProcess($instance, "Changing Hadr from $isHadrEnabled to 0 for $instance")) {
                    try {
                        Invoke-ManagedComputerCommand -ComputerName $computerFullName -Credential $Credential -ScriptBlock $scriptblock -ArgumentList $instancename
                    }
                    catch {
                        Stop-Function -Continue -Message "Failure on $($instance.FullName) | This may be because AlwaysOn Availability Groups feature requires the x86(non-WOW) or x64 Enterprise Edition of SQL Server 2012 (or later version) running on Windows Server 2008 (or later version) with WSFC hotfix KB 2494036 installed."
                    }
                }
                if (Test-Bound 'Force') {
                    if ($PSCmdlet.ShouldProcess($instance, "Force provided, restarting Engine and Agent service for $instance on $computerFullName")) {
                        try {
                            $null = Stop-DbaService -ComputerName $computerFullName -InstanceName $instanceName -Type Agent, Engine
                            $null = Start-DbaService -ComputerName $computerFullName -InstanceName $instanceName -Type Agent, Engine
                        }
                        catch {
                            Stop-Function -Message "Issue restarting $instance" -Target $instance -Continue
                        }
                    }
                }
                $newState = GetDbaAgHadr -SqlInstance $instance -Credential $Credential

                if (Test-Bound -Not -ParameterName Force) {
                    Write-Message -Level Warning -Message "You must restart the SQL Server for it to take effect."
                }

                [PSCustomObject]@{
                    ComputerName   = $newState.ComputerName
                    InstanceName   = $newState.InstanceName
                    SqlInstance    = $newState.SqlInstance
                    IsHadrEnabled  = $false
                }
            }
        }
    }
}