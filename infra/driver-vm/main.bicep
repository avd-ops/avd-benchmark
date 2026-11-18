// Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
@description('Azure region for the sandbox batch driver VM.')
param location string = resourceGroup().location

@description('VM name inside the sandbox batch resource group.')
param vmName string = 'vm-bm-driver-01'

@description('VM size sized for decoding N concurrent RDP sessions.')
param vmSize string = 'Standard_D4s_v5'

@description('Subnet resource ID in the sandbox lab VNet.')
param subnetId string

@description('Local console account username (password generated on-VM or via Key Vault at bootstrap).')
param adminUsername string = 'bmdriver'

@secure()
@description('Initial bootstrap password rotated on first boot.')
param adminPassword string

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'Windows-11'
        sku: 'win11-24h2-pro'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output driverPrincipalId string = vm.identity.principalId
output driverVmId string = vm.id
