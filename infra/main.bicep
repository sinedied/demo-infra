targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
// Flex Consumption functions are only supported in these regions.
// Run `az functionapp list-flexconsumption-locations --output table` to get the latest list
@allowed([
  'northeurope'
  'southeastasia'
  'eastasia'
  'eastus2'
  'southcentralus'
  'australiaeast'
  'eastus'
  'westus2'
  'uksouth'
  'westus3'
  'swedencentral'
])
param location string

param openaiSubdomain string = 'demo-yla'
param resourceGroupName string = ''
param webappName string = 'webapp'
param apiServiceName string = 'api'
param blobContainerName string = 'blobs'
param databaseName string = 'db'

@description('Location for the OpenAI resource group')
@allowed([
  'australiaeast'
  'canadaeast'
  'eastus'
  'eastus2'
  'westus3'
  'francecentral'
  'japaneast'
  'northcentralus'
  'swedencentral'
  'switzerlandnorth'
  'uksouth'
  'westeurope'
])
@metadata({
  azd: {
    type: 'location'
  }
})
param aiServicesLocation string // Set in main.parameters.json
param openAiApiVersion string // Set in main.parameters.json

// Location is not relevant here as it's only for the built-in api
// which is not used here. Static Web App is a global service otherwise
@description('Location for the Static Web App')
@allowed(['westus2', 'centralus', 'eastus2', 'westeurope', 'eastasia', 'eastasiastage'])
@metadata({
  azd: {
    type: 'location'
  }
})
param webappLocation string = 'eastus2'

// Id of the user or app to assign application roles
param principalId string = ''

// Differentiates between automated and manual deployments
param isContinuousIntegration bool // Set in main.parameters.json

// ---------------------------------------------------------------------------
// Services configuration

var services = loadJsonContent('services.json')

// Enable enhanced security with VNet integration
var useVnet = services.?useVnet ?? false
// Enable Azure OpenAI deployment
var useOpenAi = services.?useOpenAi ?? false
// Enable Blob storage for the Azure Functions API
var useBlobStorage = services.?useBlobStorage ?? false
// Enable Cosmos DB
var useCosmosDb = services.?useCosmosDb ?? false
// AI models configuration
var models = services.?models ?? []

// ---------------------------------------------------------------------------
// Common variables

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var shortResourceToken = substring(resourceToken, 0, 8)
var tags = { 'azd-env-name': environmentName }

var principalType = isContinuousIntegration ? 'ServicePrincipal' : 'User'
var storageAccountName = '${abbrs.storageStorageAccounts}${resourceToken}'
// var openAiUrl = useOpenAi ? 'https://${openAi.outputs.name}.openai.azure.com' : ''
var openAiUrl = useOpenAi ? 'https://${aiFoundry.outputs.aiServicesName}.openai.azure.com' : ''
var storageUrl = 'https://${storage.outputs.name}.blob.${environment().suffixes.storage}'

// ---------------------------------------------------------------------------
// Resources

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

module storage 'br/public:avm/res/storage/storage-account:0.19.0' = {
  name: 'storage'
  scope: resourceGroup
  params: {
    name: storageAccountName
    tags: tags
    location: location
    skuName: 'Standard_LRS'
    allowSharedKeyAccess: false
    publicNetworkAccess: useVnet ? null : 'Enabled'
    networkAcls: useVnet
      ? {
          defaultAction: 'Deny'
          bypass: 'AzureServices'
          virtualNetworkRules: [
            {
              id: vnet.outputs.subnetResourceIds[0]
              action: 'Allow'
            }
          ]
        }
      : {
          bypass: 'AzureServices'
          defaultAction: 'Allow'
        }
    blobServices: {
      containers: concat(
        [],
        useBlobStorage
          ? [
              {
                name: blobContainerName
                publicAccess: 'None'
              }
            ]
          : []
      )
    }
    roleAssignments: useBlobStorage
      ? [
          {
            principalId: principalId
            principalType: principalType
            roleDefinitionIdOrName: 'Storage Blob Data Contributor'
          }
        ]
      : []
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.5.2' = if (useVnet) {
  name: 'vnet'
  scope: resourceGroup
  params: {
    name: '${abbrs.networkVirtualNetworks}${resourceToken}'
    location: location
    tags: tags
    addressPrefixes: ['10.0.0.0/16']
    subnets: [
      {
        name: 'app'
        addressPrefix: '10.0.1.0/24'
        delegation: 'Microsoft.App/environments'
        serviceEndpoints: ['Microsoft.Storage']
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
    ]
  }
}

module aiFoundry 'br/public:avm/ptn/ai-ml/ai-foundry:0.2.0' = if (useOpenAi) {
  name: 'aiFoundry'
  scope: resourceGroup
  params: {
    baseName: shortResourceToken
    tags: tags
    location: aiServicesLocation
    aiFoundryConfiguration: {
      roleAssignments: [
        {
          principalId: principalId
          principalType: principalType
          roleDefinitionIdOrName: 'Cognitive Services OpenAI User'
        }
      ]
    }
    aiModelDeployments: [
      for model in models: {
        name: model.name
        model: {
          format: 'OpenAI'
          name: model.name
          version: model.?version ?? 'default'
        }
        sku: {
          name: model.?sku ?? 'Standard'
          capacity: model.capacity
        }
      }
    ]
  }
}

// module openAi 'br/public:avm/res/cognitive-services/account:0.11.0' = if (useOpenAi) {
//   name: 'openai'
//   scope: resourceGroup
//   params: {
//     name: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
//     tags: tags
//     location: aiServicesLocation
//     kind: 'OpenAI'
//     disableLocalAuth: true
//     customSubDomainName: empty(openaiSubdomain) ? '${abbrs.cognitiveServicesAccounts}${resourceToken}' : openaiSubdomain
//     publicNetworkAccess: 'Enabled'
//     deployments: [
//       for model in models: {
//         name: model.name
//         model: {
//           format: 'OpenAI'
//           name: model.name
//           version: model.?version ?? 'default'
//         }
//         sku: {
//           name: model.?sku ?? 'Standard'
//           capacity: model.capacity
//         }
//       }
//     ]
//     roleAssignments: [
//       {
//         principalId: principalId
//         principalType: principalType
//         roleDefinitionIdOrName: 'Cognitive Services OpenAI User'
//       }
//     ]
//   }
// }

module cosmosDb 'br/public:avm/res/document-db/database-account:0.12.0' = {
  name: 'cosmosDb'
  scope: resourceGroup
  params: {
    name: '${abbrs.documentDBDatabaseAccounts}${resourceToken}'
    tags: tags
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    managedIdentities: {
      systemAssigned: true
    }
    capabilitiesToAdd: [
      'EnableServerless'
      'EnableNoSQLVectorSearch'
    ]
    networkRestrictions: {
      ipRules: []
      virtualNetworkRules: []
      publicNetworkAccess: 'Enabled'
    }
    sqlDatabases: [
      {
        containers: []
        name: databaseName
      }
    ]
    sqlRoleDefinitions: [
      {
        name: 'db-contrib-role-definition'
        roleName: 'Reader Writer'
        roleType: 'CustomRole'
        dataAction: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
        ]
      }
    ]
    sqlRoleAssignmentsPrincipalIds: useCosmosDb ? [principalId] : []
  }
}

// ---------------------------------------------------------------------------
// System roles assignation

// ---------------------------------------------------------------------------
// Outputs

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = resourceGroup.name

output AZURE_OPENAI_ENDPOINT string = openAiUrl
output AZURE_OPENAI_INSTANCE_NAME string = useOpenAi ? aiFoundry.outputs.aiServicesName : ''
output AZURE_OPENAI_API_VERSION string = openAiApiVersion

output AZURE_STORAGE_URL string = storageUrl
output AZURE_STORAGE_CONTAINER_NAME string = useBlobStorage ? blobContainerName : ''

output AZURE_COSMOSDB_NOSQL_ENDPOINT string = useCosmosDb ? cosmosDb.outputs.endpoint : ''
