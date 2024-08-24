targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

param resourceGroupName string = ''

@description('Location for the OpenAI resource group')
@allowed(['australiaeast', 'canadaeast', 'eastus', 'eastus2', 'francecentral', 'japaneast', 'northcentralus', 'swedencentral', 'switzerlandnorth', 'uksouth', 'westeurope'])
@metadata({
  azd: {
    type: 'location'
  }
})
param openAiLocation string // Set in main.parameters.json
param openAiSkuName string = 'S0'
param openAiApiVersion string // Set in main.parameters.json

// Id of the user or app to assign application roles
param principalId string = ''

// Differentiates between automated and manual deployments
param isContinuousDeployment bool // Set in main.parameters.json

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var config = loadJsonContent('config.json')
var disableLocalAuth = false

// Organize resources in a resource group
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

module openAi 'core/ai/cognitiveservices.bicep' = {
  name: 'openai'
  scope: resourceGroup
  params: {
    name: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: openAiLocation
    tags: tags
    sku: {
      name: openAiSkuName
    }
    disableLocalAuth: disableLocalAuth
    deployments: [for model in config.models: {
      name: model.?alias ?? model.name
      model: {
        format: 'OpenAI'
        name: model.name
        version: model.version
      }
      sku: {
        name: model.?sku ?? 'Standard'
        capacity: model.capacity
      }
      raiPolicyName: 'Microsoft.DefaultV2'
    }]
  }
}

module cosmosDb './core/database/cosmos/sql/cosmos-sql-db.bicep' = {
  name: 'cosmosDb'
  scope: resourceGroup
  params: {
    accountName: '${abbrs.documentDBDatabaseAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [
      {
        name: 'vectorSearchContainer'
        id: 'vectorSearchContainer'
        partitionKey: '/id'
      }
    ]
    databaseName: 'vectorSearchDB'
    disableLocalAuth: disableLocalAuth
  }
}

module cosmosVcore 'core/database/cosmos-mongo-db-vcore.bicep' = {
  name: 'cosmos-mongo'
  scope: resourceGroup
  params: {
    accountName: '${abbrs.documentDBDatabaseAccounts}vcore${resourceToken}'
    administratorLogin: 'admin${resourceToken}'
    skuName: 'Free'
    location: location
    tags: tags
  }
}

module searchService 'core/search/search-services.bicep' = {
  name: 'search-service'
  scope: resourceGroup
  params: {
    name: '${abbrs.searchSearchServices}${resourceToken}'
    location: location
    tags: tags
    disableLocalAuth: disableLocalAuth
    authOptions: null
    sku: {
      name: 'basic'
    }
    semanticSearch: 'free'
  }
}

module storage './core/storage/storage-account.bicep' = {
  name: 'storage'
  scope: resourceGroup
  params: {
    name: '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [
      {
        name: 'env'
        publicAccess: 'None'
      }
    ]
  }
}

// Managed identity roles assignation
// ---------------------------------------------------------------------------

// User roles
module openAiRoleUser 'core/security/role.bicep' = if (!isContinuousDeployment) {
  scope: resourceGroup
  name: 'openai-role-user'
  params: {
    principalId: principalId
    // Cognitive Services OpenAI User
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    principalType: 'User'
  }
}

module speechRoleUser 'core/security/role.bicep' = if (!isContinuousDeployment) {
  scope: resourceGroup
  name: 'speech-role-user'
  params: {
    principalId: principalId
    // Cognitive Services Speech User
    roleDefinitionId: 'f2dc8367-1007-4938-bd23-fe263f013447'
    principalType: 'User'
  }
}

module dbContribRoleUser './core/database/cosmos/sql/cosmos-sql-role-assign.bicep' = if (!isContinuousDeployment) {
  scope: resourceGroup
  name: 'db-contrib-role-user'
  params: {
    accountName: cosmosDb.outputs.accountName
    principalId: principalId
    // Cosmos DB Data Contributor
    roleDefinitionId: cosmosDb.outputs.roleDefinitionId
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = resourceGroup.name

output AZURE_OPENAI_API_ENDPOINT string = 'https://${openAi.outputs.name}.openai.azure.com'
output AZURE_OPENAI_API_KEY string = openAi.outputs.key
output AZURE_OPENAI_API_INSTANCE_NAME string = openAi.outputs.name
output AZURE_OPENAI_API_VERSION string = openAiApiVersion

output AZURE_COSMOSDB_NOSQL_ENDPOINT string = cosmosDb.outputs.endpoint
output AZURE_COSMOSDB_NOSQL_CONNECTION_STRING string = cosmosDb.outputs.connectionString

output AZURE_COSMOSDB_MONGODB_VCORE_CONNECTION_STRING string = cosmosVcore.outputs.connectionString

output AZURE_AISEARCH_ENDPOINT string = searchService.outputs.endpoint
output AZURE_AISEARCH_ADMIN_KEY string = searchService.outputs.key
