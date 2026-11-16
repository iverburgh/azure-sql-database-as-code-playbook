BeforeDiscovery {
    $script:Examples = @(
        @{ Name = 'environments.json'; Schema = 'environments.schema.json'; Path = 'database/environments.json' }
        @{ Name = 'captured-columns.json'; Schema = 'captured-columns.schema.json'; Path = 'database/cdc/captured-columns.json' }
        @{ Name = 'ColumnDescriptions.json'; Schema = 'column-descriptions.schema.json'; Path = 'database/Shop.Database/ColumnDescriptions.json' }
    )
}

BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    function Test-AgainstSchema([string] $Json, [string] $Schema) {
        Test-Json -Json $Json -SchemaFile (Join-Path $SchemaPath $Schema) -ErrorAction SilentlyContinue
    }
}

Describe 'The example files' {
    It '<Name> matches <Schema>' -TestCases $Examples {
        $json = [System.IO.File]::ReadAllText((Join-Path $PlaybookRoot $Path))
        Test-AgainstSchema -Json $json -Schema $Schema | Should -BeTrue
    }

    It '<Name> points its $schema at <Schema>' -TestCases $Examples {
        $document = Read-JsonFile -Path (Join-Path $PlaybookRoot $Path)
        $resolved = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent (Join-Path $PlaybookRoot $Path)) $document['$schema']))
        $resolved | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $SchemaPath $Schema)))
    }
}

Describe 'The schemas reject' {
    It '<Case>' -TestCases @(
        @{ Case = 'a protected environment with test data'; Schema = 'environments.schema.json'; Json = '{ "environments": { "Production": { "seedConfiguration": "Production", "testData": true, "allowDropAll": false, "protected": true } } }' }
        @{ Case = 'a protected environment that allows DropAll'; Schema = 'environments.schema.json'; Json = '{ "environments": { "Production": { "seedConfiguration": "Production", "testData": false, "allowDropAll": true, "protected": true } } }' }
        @{ Case = 'an environment without protected'; Schema = 'environments.schema.json'; Json = '{ "environments": { "Test": { "seedConfiguration": "Test", "testData": true, "allowDropAll": false } } }' }
        @{ Case = 'an unknown environment setting'; Schema = 'environments.schema.json'; Json = '{ "environments": { "Test": { "seedConfiguration": "Test", "testData": true, "allowDropAll": false, "protected": false, "region": "x" } } }' }
        @{ Case = 'a captured table without schema'; Schema = 'captured-columns.schema.json'; Json = '{ "tables": { "Order": [ "OrderId" ] } }' }
        @{ Case = 'a captured table without columns'; Schema = 'captured-columns.schema.json'; Json = '{ "tables": { "Sales.Order": [] } }' }
        @{ Case = 'descriptions without excludedTables'; Schema = 'column-descriptions.schema.json'; Json = '{ "standardColumns": {}, "tables": {} }' }
        @{ Case = 'a described table without columns'; Schema = 'column-descriptions.schema.json'; Json = '{ "standardColumns": {}, "excludedTables": [], "tables": { "Sales.Order": { "description": "An order." } } }' }
        @{ Case = 'a description that is not text'; Schema = 'column-descriptions.schema.json'; Json = '{ "standardColumns": {}, "excludedTables": [], "tables": { "Sales.Order": { "description": "An order.", "columns": { "OrderId": 1 } } } }' }
    ) {
        Test-AgainstSchema -Json $Json -Schema $Schema | Should -BeFalse
    }
}
