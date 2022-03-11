# AS2AZ
Script to transfer Availability Set to Availability Zone

The script is based on a previous code https://aztoso.com/posts/migrate-virtual-machine-into-availability-zone/

Only applicable for moving virtual machine in availability set to availability zone in same region.

For moving in seperate region please make use of Azure Site Recovery or Azure Resource Mover

Ensure you have backup and proper images for the virtual machines you want to migrate and proper downtime and contingency plan has been in place.

For the virtual machines you want to migrate to availability zone add Tag "ZoneNumber" and number 1, 2 or 3

Then run this script, it will iterate all vms in your system and check for this Tag.

Once Tag is read the script will move resources to marked zone.
