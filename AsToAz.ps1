

$subscriptionId="3a647977-f78c-47f0-82c2-fe4d8e60bb77" #Set to your subscription id where the VM is created
$location = "SouthEastAsia" #VM Location


#Login to the Azure
Login-AzAccount

#Set the subscription
Set-AzContext -Subscription $subscriptionId

#List all VMs in subscription
$vmList = Get-AzVM 


foreach($vm in $vmList){
    #if vm already in zone skip
    if($vm.Zones -gt 0){
     $vm.Name + ' already in zone ' + $vm.Zones
     continue
    }
    $vm.Name + 'should not reach'
}

foreach($vm in $vmList){
    #if vm already in zone skip
    if($vm.Zones -gt 0){
     $vm.Name + ' already in zone ' + $vm.Zones
     continue
    }

	#Read Tags
    $resourceGroup = $vm.ResourceGroupName
    $vmName = $vm.Name
    $tags = (Get-AzResource -ResourceGroupName $resourceGroup -Name $vm.Name).Tags
	$zone = $tags['ZoneNumber'] 
    if($zone -eq ''){
        'Virtual Machine:' + $vm.Name + ' | ResourceGroup:' + $vm.ResourceGroupName + ' missing zone tag - Skipped'
        continue;
    }   
    
    'Starting zone transfer for vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName

    $originalVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName

    'Stopping vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName
    # Stop the VM to take snapshot
    Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force 
    'Stopped vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName
    
    'Starting snapshot of os disks for  vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName
    
    # Create a SnapShot of the OS disk and then, create an Azure Disk with Zone information
    $snapshotOSConfig = New-AzSnapshotConfig -SourceUri $originalVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS
    $OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $resourceGroup 
    $diskSkuOS = (Get-AzDisk -DiskName $originalVM.StorageProfile.OsDisk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name

    $diskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName  $diskSkuOS -Zone $zone 
    $OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName ($originalVM.StorageProfile.OsDisk.Name + "zone")

    'Completed snapshot of os disks for  vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName
    
    'Starting snapshot of data disks for  vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName

    # Create a Snapshot from the Data Disks and the Azure Disks with Zone information
    foreach ($disk in $originalVM.StorageProfile.DataDisks) { 

       $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS
       $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $resourceGroup

       $diskSkuData = (Get-AzDisk -DiskName $disk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name
       $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $diskSkuData -Zone $zone
       $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $resourceGroup -DiskName ($disk.Name + "zone")
    }
    'Completed snapshot of os disks for  vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName

    'Removing original  vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName
    # Remove the original VM
    Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName  -Force
    'Removed original  vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName

    'Creating new vm ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName + ' in zone:' + $zone

    # Create the basic configuration for the replacement VM
    $newVM = New-AzVMConfig -VMName $originalVM.Name -VMSize $originalVM.HardwareProfile.VmSize -Zone $zone -tags $tags

    # Add the pre-existed OS disk 
    Set-AzVMOSDisk -VM $newVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows

    # Add the pre-existed data disks
    foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
        $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName ($disk.Name + "zone")
        Add-AzVMDataDisk -VM $newVM -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach 
    }
    
    'Copied OS and Data Disks for ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName + ' in zone:' + $zone

    'Attaching network interfaces for ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName + ' in zone:' + $zone

    # Add NIC(s) and keep the same NIC as primary
    # If there is a Public IP from the Basic SKU remove it because it doesn't supports zones
    foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {  
       $netInterface = Get-AzNetworkInterface -ResourceId $nic.Id 
       $publicIPId = $netInterface.IpConfigurations[0].PublicIpAddress.Id
       $publicIP = Get-AzPublicIpAddress -Name $publicIPId.Substring($publicIPId.LastIndexOf("/")+1) 
       if ($publicIP)
       {      
          if ($publicIP.Sku.Name -eq 'Basic')
          {
             $netInterface.IpConfigurations[0].PublicIpAddress = $null
             Set-AzNetworkInterface -NetworkInterface $netInterface
          }
       }
       if ($nic.Primary -eq "True")
       {
          Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -Primary
       }
       else
       {
          Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id 
       }
    }

    'Provisioning new ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName + ' in zone:' + $zone


    # Recreate the VM
    $newlyVM = New-AzVM -ResourceGroupName $resourceGroup -Location $originalVM.Location -VM $newVM -DisableBginfoExtension

    'Provisioned new ' + $vm.Name + ' | ResourceGroup: ' + $vm.ResourceGroupName + ' in zone:' + $zone

    # If the machine is SQL server, create a new SQL Server object
    #New-AzSqlVM -ResourceGroupName $resourceGroup -Name $newVM.Name -Location $location -LicenseType PAYG 

}