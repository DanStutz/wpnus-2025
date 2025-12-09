Param
(
    [CmdletBinding()]
    #.Parameter Verbose
    # A switch to specify whether verbose output should be displayed
    [Parameter(Position=1, ParameterSetName='default', Mandatory=$False)]
    [switch]$Verbose,
    
    # .PARAMETER CSVPath
    # Parameter expects a string object (e.g., $csvPath = 'C:\Users\dstutz\Documents\fullnameoffile.csv')
    [Parameter(Position=0, ParameterSetName='default', Mandatory=$True)]
    [string]$csvPath
)

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"

# Import the CSV
$devices = Import-Csv -Path "$csvPath"

foreach ($device in $devices) {
    $serialNumber = $device.SerialNumber
    $groupTag = $device.GroupTag

    try {
        # Get the device by serial number
        $deviceDetails = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serialNumber')"

        if ($deviceDetails) {
            # Update the group tag for the device
            Update-MgDeviceManagementWindowsAutopilotDeviceIdentityDeviceProperty -WindowsAutopilotDeviceIdentityId $deviceDetails.Id -GroupTag $groupTag

            Write-Host "Successfully updated group tag for device with serial number $serialNumber." -ForegroundColor Green
        } else {
            Write-Output "No device found with serial number $serialNumber." -ForegroundColor Yellow
        }
    } catch {
        Write-Error "An error occurred while processing the device with serial number $serialNumber : $_"
    }
}
