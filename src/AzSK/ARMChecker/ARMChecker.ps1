Set-StrictMode -Version Latest

function Get-AzSKARMTemplateSecurityStatus
{
	<#
	.SYNOPSIS
	This command would help in evaluating the ARM Templates for security issues
	.DESCRIPTION
	This command would help in evaluating the ARM Templates for security issues
	
	.PARAMETER ARMTemplatePath
		Path to ARM Template file or folder

    .PARAMETER Recurse
		Gets the ARM Temaplates in the specified locations and in all child folders of the locations	

	.PARAMETER DoNotOpenOutputFolder
		Switch to specify whether to open output folder containing all security evaluation report or not

    .PARAMETER ExcludeFiles
		Comma-separated list of JSON files to be excluded from scan

    .PARAMETER SkipControlsFromFile
		Path to file containing list of controls to skip

	.LINK
	https://aka.ms/azskossdocs 

	#>
	Param(
        [Parameter(Mandatory = $true, HelpMessage = "Path to ARM Template file or folder")]
        [string]        
		[Alias("atp")]
        $ARMTemplatePath,

		[Parameter(Mandatory = $false, HelpMessage = "Path to Template paramter file or folder")]
        [string]        
		[Alias("pfp")]
        $ParameterFilePath,

		[Parameter(Mandatory = $false, HelpMessage = "Gets the ARM Temaplates in the specified locations and in all child folders of the locations")]
        [switch]  
		[Alias("rcs")]
        $Recurse,

		[switch]
        [Parameter(Mandatory = $false, HelpMessage = "Switch to specify whether to open output folder containing all security evaluation report or not")]
		[Alias("dnof")]
		$DoNotOpenOutputFolder,

		[Parameter(Mandatory = $false, HelpMessage = "Comma-separated list of JSON files to be excluded from scan")]
        [string]  
		[Alias("ef")]
		$ExcludeFiles,
		
		[string] 
		[Parameter(Mandatory = $false, HelpMessage = "Comma-separated list of control ids to be excluded from scan")]		
		[Alias("xcids")]
		[AllowEmptyString()]
		$ExcludeControlIds,

		[string] 
        [Parameter(Mandatory = $false, HelpMessage="Comma separated control ids to filter the security controls. e.g.: Azure_Subscription_AuthZ_Limit_Admin_Owner_Count, Azure_Storage_DP_Encrypt_At_Rest_Blob etc.")]
		[Alias("cids")]
		[AllowEmptyString()]
		$ControlIds,
		
		[switch]
		[Parameter(Mandatory = $false)]
		[Alias("ubc")]
		$UseBaselineControls,

		[switch]
		[Parameter(Mandatory = $false)]
		[Alias("upbc")]
		$UsePreviewBaselineControls,

		[string] 
		[Parameter(Mandatory = $false, HelpMessage="Specify the severity of controls to be scanned. Example `"High, Medium`"")]
		[Alias("ControlSeverity")]
		$Severity,


		[Parameter(Mandatory = $false, HelpMessage = "Path to file containing list of controls to skip")]
        [string]  
		[Alias("scf")]
        $SkipControlsFromFile
    )

	Begin
	{
	    [AIOrgTelemetryHelper]::PublishARMCheckerEvent("ARMChecker Command Started",@{}, $null)
	}

	Process
	{
		try 
		{
			$armStatus = [ARMCheckerStatus]::new($PSCmdlet.MyInvocation);
			if ($armStatus) 
			{
				return $armStatus.EvaluateStatus($ARMTemplatePath,$ParameterFilePath,$Recurse,$SkipControlsFromFile,$ExcludeFiles,$ExcludeControlIds,$ControlIds,$UseBaselineControls,$UsePreviewBaselineControls, $Severity);				
			}    
		}
		catch 
		{
			$formattedMessage = [Helpers]::ConvertObjectToString($_, $false);		
			Write-Host $formattedMessage -ForegroundColor Red
		    [AIOrgTelemetryHelper]::PublishARMCheckerEvent("ARMChecker Command Error",@{"Exception"=$_}, $null)
		}  
	}
	End
	{
		
	}
}

