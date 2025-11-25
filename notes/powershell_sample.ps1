using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$name = $Request.Query.Name
if (-not $name) {
    $name = $Request.Body.Name
}

function ConvertTo-QueryString {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object
    )
    
    $pairs = @()
    
    if ($Object -is [hashtable]) {
        $items = $Object.GetEnumerator()
    }
    elseif ($Object -is [PSCustomObject]) {
        $items = $Object.PSObject.Properties
    }
    else {
        throw "Object must be a hashtable or PSCustomObject"
    }
    
    foreach ($item in $items) {
        $key = if ($item.Key) { $item.Key } else { $item.Name }
        $value = if ($item.Value) { $item.Value } else { $item.Value }
        
        if ($null -ne $value) {
            $encodedKey = [Uri]::EscapeDataString($key)
            $encodedValue = [Uri]::EscapeDataString($value.ToString())
            $pairs += "$encodedKey=$encodedValue"
        }
    }
    
    return $pairs -join '&'
}

function ConvertFrom-QueryString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueryString
    )
    $Body = $QueryString.Replace('"', '') -split '&'
    return $Body
}

function Parse-RequestBody {
    param(
        [Parameter(Mandatory = $true)]
        $Body
    )
    
    [System.Collections.ArrayList]$BodyParams = @()
    
    if ($null -eq $Body) {
        return $BodyParams
    }
    
    # Handle string format (query string)
    if ($Body -is [string]) {
        if ($Body.Trim().StartsWith('{') -or $Body.Trim().StartsWith('[')) {
            # Try to parse as JSON
            try {
                $Body = $Body | ConvertFrom-Json
            }
            catch {
                Write-Host "Failed to parse body as JSON, treating as query string: $($_.Exception.Message)"
                $Body = ConvertFrom-QueryString -QueryString $Body
            }
        }
        else {
            # Treat as query string
            $Body = ConvertFrom-QueryString -QueryString $Body
        }
    }
    
    # Handle PSCustomObject (from JSON)
    if ($Body -is [PSCustomObject]) {
        $Body.PSObject.Properties | ForEach-Object {
            $Params = "" | Select-Object Key, Value
            $Params.Key = $_.Name
            $Params.Value = $_.Value
            $BodyParams += $Params
        }
        return $BodyParams
    }
    
    # Handle hashtable
    if ($Body -is [hashtable]) {
        $Body.GetEnumerator() | ForEach-Object {
            $Params = "" | Select-Object Key, Value
            $Params.Key = $_.Key
            $Params.Value = $_.Value
            $BodyParams += $Params
        }
        return $BodyParams
    }
    
    # Handle array of strings (from query string parsing)
    if ($Body -is [array]) {
        foreach ($Item in $Body) {
            if ($Item -is [string]) {
                $Params = "" | Select-Object Key, Value
                $ItemParts = $Item -split '=', 2
                $Params.Key = $ItemParts[0]
                if ($ItemParts.Length -gt 1) {
                    $Params.Value = $ItemParts[1]
                }
                else {
                    $Params.Value = $null
                }
                $BodyParams += $Params
            }
        }
        return $BodyParams
    }
    
    return $BodyParams
}
function Rewrite-CheckPointAuthRequest {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Request,
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$BodyParams
    )
    $NewRequest = "" | Select-Object Headers, Body, Method, RequestUri
    Write-Host "Copying the client_id and client_secret from the request body to the new request body"
    $Content = @{
        clientId  = $BodyParams | Where-Object { $_.Key -eq 'client_id' } | Select-Object -ExpandProperty Value
        accessKey = $BodyParams | Where-Object { $_.Key -eq 'client_secret' } | Select-Object -ExpandProperty Value
    }
    $NewRequest.Body = (ConvertTo-Json $Content)
    $NewRequest.Method = "POST"
    $NewRequest.RequestUri = 'https://cloudinfra-gw.portal.checkpoint.com/auth/external'
    $NewRequest.Headers = @{
        'Content-Type' = 'application/json'
    }

    return $NewRequest
}

function Get-CheckPointAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        $NewRequest
    )
    $Response = Invoke-WebRequest -Method $NewRequest.Method -Uri $NewRequest.RequestUri -Headers $NewRequest.Headers -Body $NewRequest.Body
    Write-Host "Original Response:"
    Write-Host ($Response | Out-String)
    $ResponseContent = $Response.Content | ConvertFrom-Json
    # Checkpoint response with the access token at this JPath: $.data.token, but we need to set it to be at this path: $.access_token
    $NewResponse = "" | Select-Object Content, StatusCode, StatusDescription
    $Content = @{
        access_token = $ResponseContent.data.token
        token_type   = "Bearer"
    }
    
    # Include CSRF token if present in response
    if ($ResponseContent.data.csrf) {
        $Content.csrf = $ResponseContent.data.csrf
    }
    
    # Include expires_in if present
    if ($ResponseContent.data.expiresIn) {
        $Content.expires_in = $ResponseContent.data.expiresIn
    }
    elseif ($ResponseContent.data.expires) {
        $Content.expires_in = $ResponseContent.data.expires
    }
    
    $NewResponse.Content = $Content
    $NewResponse.StatusCode = $Response.StatusCode
    $NewResponse.StatusDescription = $Response.StatusDescription
    return $NewResponse
}

function Build-CheckpointLogDataRequest {
    param(
        [Parameter(Mandatory = $true)]
        $Request,
        [Parameter(Mandatory = $false)]
        $CheckPointUrl = "https://cloudinfra-gw-us.portal.checkpoint.com/app/hec-api/v1.0/search/query",
        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalParams = @{}
    )

    Write-Host "Building Checkpoint log data request"
    Write-Host "Request:"
    Write-Host ($Request | ConvertTo-Json -Depth 10 | Out-String)
    
    # Parse request body to extract access_token and csrf
    $BodyParams = Parse-RequestBody -Body $Request.Body
    
    # Also check Authorization header if present
    $AccessToken = $null
    $Csrf = $null
    
    # Try to get access_token from body params
    $AccessToken = $BodyParams | Where-Object { $_.Key -eq 'access_token' } | Select-Object -ExpandProperty Value
    
    # Try to get csrf from body params
    $Csrf = $BodyParams | Where-Object { $_.Key -eq 'csrf' } | Select-Object -ExpandProperty Value
    
    # If not in body, check Authorization header
    if ([string]::IsNullOrWhiteSpace($AccessToken) -and $Request.Headers) {
        $authHeader = $null
        foreach ($headerKey in $Request.Headers.Keys) {
            if ($headerKey -eq 'authorization' -or $headerKey -eq 'Authorization' -or $headerKey -eq 'AUTHORIZATION') {
                $authHeader = $Request.Headers[$headerKey]
                break
            }
        }
        
        if ($authHeader -and $authHeader -match '^Bearer\s+(.+)$') {
            $AccessToken = $matches[1]
            Write-Host "Extracted access token from Authorization header"
        }
    }
    
    # Get CSRF from header if not in body
    if ([string]::IsNullOrWhiteSpace($Csrf) -and $Request.Headers) {
        $csrfHeader = $null
        foreach ($headerKey in $Request.Headers.Keys) {
            if ($headerKey -eq 'x-av-req-id' -or $headerKey -eq 'X-AV-Req-Id' -or $headerKey -eq 'X-AV-REQ-ID') {
                $csrfHeader = $Request.Headers[$headerKey]
                break
            }
        }
        if ($csrfHeader) {
            $Csrf = $csrfHeader
            Write-Host "Extracted CSRF from header"
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw "Missing required parameter: access_token is required for Checkpoint log data requests"
    }
    
    # Build request object
    $LogRequest = "" | Select-Object Headers, Body, Method, RequestUri
    
    # Build headers
    $RequestHeaders = @{
        Accept        = 'application/json'
        Authorization = "Bearer $AccessToken"
    }
    
    if (-not [string]::IsNullOrWhiteSpace($Csrf)) {
        $RequestHeaders['x-av-req-id'] = $Csrf
    }
    
    # Add any additional headers from AdditionalParams
    if ($AdditionalParams.ContainsKey('Headers')) {
        foreach ($key in $AdditionalParams.Headers.Keys) {
            $RequestHeaders[$key] = $AdditionalParams.Headers[$key]
        }
    }
    
    $LogRequest.Headers = $RequestHeaders
    
    # Build body - support both GET and POST
    if ($Request.Method -eq "POST" -and $Request.Body) {
        # For POST requests, preserve the body or use AdditionalParams
        if ($AdditionalParams.ContainsKey('Body')) {
            $LogRequest.Body = $AdditionalParams.Body
        }
        else {
            # Try to extract query parameters from body for Checkpoint API
            $queryParams = @{}
            $BodyParams | Where-Object { $_.Key -ne 'access_token' -and $_.Key -ne 'csrf' -and $_.Key -ne 'key' -and $_.Key -ne 'value' } | ForEach-Object {
                $queryParams[$_.Key] = $_.Value
            }
            if ($queryParams.Count -gt 0) {
                $LogRequest.Body = (ConvertTo-Json $queryParams)
            }
            else {
                $LogRequest.Body = $null
            }
        }
    }
    else {
        $LogRequest.Body = $null
    }
    
    # Determine method - use from AdditionalParams or default to GET
    if ($AdditionalParams.ContainsKey('Method')) {
        $LogRequest.Method = $AdditionalParams.Method
    }
    else {
        $LogRequest.Method = "GET"
    }
    
    # Build URL - support query parameters
    $uriBuilder = [System.UriBuilder]$CheckPointUrl
    if ($AdditionalParams.ContainsKey('QueryParams')) {
        $queryString = ""
        foreach ($key in $AdditionalParams.QueryParams.Keys) {
            if ($queryString) { $queryString += "&" }
            $queryString += [Uri]::EscapeDataString($key) + "=" + [Uri]::EscapeDataString($AdditionalParams.QueryParams[$key].ToString())
        }
        if ($queryString) {
            if ($uriBuilder.Query) {
                $uriBuilder.Query = $uriBuilder.Query.TrimStart('?') + "&" + $queryString
            }
            else {
                $uriBuilder.Query = $queryString
            }
        }
    }
    
    $LogRequest.RequestUri = $uriBuilder.Uri.ToString()
    
    Write-Host "Built Checkpoint log data request:"
    Write-Host "Method: $($LogRequest.Method)"
    Write-Host "URI: $($LogRequest.RequestUri)"
    Write-Host "Headers: $($LogRequest.Headers | ConvertTo-Json)"
    
    return $LogRequest
}

function Invoke-CheckpointLogDataRequest {
    param(
        [Parameter(Mandatory = $true)]
        $LogRequest
    )
    
    Write-Host "Invoking Checkpoint log data request"
    
    try {
        $params = @{
            Method = $LogRequest.Method
            Uri    = $LogRequest.RequestUri
            Headers = $LogRequest.Headers
        }
        
        if ($LogRequest.Body) {
            $params.Body = $LogRequest.Body
        }
        
        $LogDataResponse = Invoke-WebRequest @params -UseBasicParsing
        
        Write-Host "Checkpoint log data response received:"
        Write-Host "StatusCode: $($LogDataResponse.StatusCode)"
        Write-Host "Content length: $($LogDataResponse.Content.Length)"
        
        # Return response object
        $Response = "" | Select-Object Content, StatusCode, StatusDescription, Headers
        $Response.Content = $LogDataResponse.Content
        $Response.StatusCode = $LogDataResponse.StatusCode
        $Response.StatusDescription = $LogDataResponse.StatusDescription
        $Response.Headers = $LogDataResponse.Headers
        
        return $Response
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "Error invoking Checkpoint log data request: $errorMessage"
        
        $Response = "" | Select-Object Content, StatusCode, StatusDescription, Headers
        if ($_.Exception.Response) {
            $Response.StatusCode = $_.Exception.Response.StatusCode.value__
            $Response.StatusDescription = $_.Exception.Response.StatusDescription
            try {
                $errorStream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($errorStream)
                $errorBody = $reader.ReadToEnd()
                $Response.Content = $errorBody
            }
            catch {
                $Response.Content = @{ error = $errorMessage } | ConvertTo-Json
            }
        }
        else {
            $Response.StatusCode = [HttpStatusCode]::InternalServerError
            $Response.StatusDescription = "Internal Server Error"
            $Response.Content = @{ error = $errorMessage } | ConvertTo-Json
        }
        
        return $Response
    }
}

function Get-CheckpointLogData {
    param(
        [Parameter(Mandatory = $true)]
        $Request,
        [Parameter(Mandatory = $false)]
        $CheckPointUrl = "https://cloudinfra-gw-us.portal.checkpoint.com/app/hec-api/v1.0/search/query",
        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalParams = @{}
    )
    
    $LogRequest = Build-CheckpointLogDataRequest -Request $Request -CheckPointUrl $CheckPointUrl -AdditionalParams $AdditionalParams
    $Response = Invoke-CheckpointLogDataRequest -LogRequest $LogRequest
    return $Response
}

function Rewrite-MicrosoftGraphAuthRequest {
    param (
        [Parameter(Mandatory = $true)]
        $Request,
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$BodyParams
    )
    $NewRequest = "" | Select-Object Headers, Body, Method, RequestUri
    
    # Try to get client_id and client_secret from body params first
    $clientId = $BodyParams | Where-Object { $_.Key -eq 'client_id' } | Select-Object -ExpandProperty Value
    $clientSecret = $BodyParams | Where-Object { $_.Key -eq 'client_secret' } | Select-Object -ExpandProperty Value
    
    # If not in body, try to extract from Authorization header (Basic auth)
    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
        if ($Request.Headers) {
            # Find authorization header (case-insensitive)
            $authHeader = $null
            foreach ($headerKey in $Request.Headers.Keys) {
                if ($headerKey -eq 'authorization' -or $headerKey -eq 'Authorization' -or $headerKey -eq 'AUTHORIZATION') {
                    $authHeader = $Request.Headers[$headerKey]
                    Write-Host "Found Authorization header: $headerKey"
                    break
                }
            }
            
            if ($authHeader -and $authHeader -match '^Basic\s+(.+)$') {
                try {
                    $base64Credentials = $matches[1]
                    $decodedBytes = [System.Convert]::FromBase64String($base64Credentials)
                    $decodedString = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
                    $credentials = $decodedString -split ':', 2
                    if ($credentials.Length -eq 2) {
                        if ([string]::IsNullOrWhiteSpace($clientId)) {
                            $clientId = $credentials[0]
                        }
                        if ([string]::IsNullOrWhiteSpace($clientSecret)) {
                            $clientSecret = $credentials[1]
                        }
                        Write-Host "Extracted credentials from Authorization header"
                    }
                }
                catch {
                    Write-Host "Error decoding Authorization header: $($_.Exception.Message)"
                }
            }
            elseif ($authHeader) {
                Write-Host "Authorization header found but not in Basic format: $($authHeader.Substring(0, [Math]::Min(20, $authHeader.Length)))..."
            }
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
        throw "Missing required parameters: client_id and client_secret are required for Microsoft Graph authentication. They must be provided in the request body or Authorization header."
    }
    
    $grantType = $BodyParams | Where-Object { $_.Key -eq 'grant_type' } | Select-Object -ExpandProperty Value
    if ([string]::IsNullOrWhiteSpace($grantType)) {
        $grantType = "client_credentials"
    }
    
    $Content = @{
        client_id     = $clientId
        resource      = "https://graph.microsoft.com"
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $clientSecret
        grant_type    = $grantType
    }
    $NewRequest.Body = (ConvertTo-QueryString $Content)
    $NewRequest.Method = "POST"
    $NewRequest.RequestUri = 'https://login.microsoftonline.com/567c7a62-8edb-4ead-9138-56f4bd08d619/oauth2/token'
    $NewRequest.Headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
    return $NewRequest
}

function Get-MicrosoftGraphAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        $NewRequest
    )
    $Response = Invoke-WebRequest -Method $NewRequest.Method -Uri $NewRequest.RequestUri -Headers $NewRequest.Headers -Body $NewRequest.Body -UseBasicParsing
    return $Response
}

$body = "This HTTP triggered function executed successfully."

Write-Host "Full Request:"
Write-Host ($Request | ConvertTo-Json -Depth 10 | Out-String)


$OriginalRequest = $Request
$AuthResponse = $null
$LogDataResponse = $null
$ResponseStatusCode = $null

# Parse request body to detect application type
$BodyParams = Parse-RequestBody -Body $Request.Body
$Application = $null
$AutoFetchLogs = $false

# Check if this is an authenticated log data request or an auth request
$IsAuthenticatedRequest = $false

# Check for application identifier in body
foreach ($Param in $BodyParams) {
    if ($Param.Key -eq "key" -and $Param.Value -eq "Application") {
        $appValueParam = $BodyParams | Where-Object { $_.Key -eq "value" }
        if ($appValueParam) {
            $Application = $appValueParam.Value
            break
        }
    }
}

# Also check for auto_fetch_logs parameter
$autoFetchParam = $BodyParams | Where-Object { $_.Key -eq "auto_fetch_logs" -or $_.Key -eq "autoFetchLogs" }
if ($autoFetchParam) {
    $AutoFetchLogs = ($autoFetchParam.Value -eq "true" -or $autoFetchParam.Value -eq "1" -or $autoFetchParam.Value -eq $true)
}

# Check query parameters for auto_fetch_logs
if (-not $AutoFetchLogs -and $Request.Query) {
    if ($Request.Query.auto_fetch_logs -or $Request.Query.autoFetchLogs) {
        $AutoFetchLogs = ($Request.Query.auto_fetch_logs -eq "true" -or $Request.Query.autoFetchLogs -eq "true" -or $Request.Query.auto_fetch_logs -eq "1" -or $Request.Query.autoFetchLogs -eq "1")
    }
}

if ($Application) {
    Write-Host "Application found in the request: $Application"
    Write-Host "BodyParams: $($BodyParams | ConvertTo-Json)"
    
    $NewRequest = $null
    
    switch ($Application) {
        "Checkpoint" {
            # Check if this is an authenticated request (has access_token)
            # Fix operator precedence: (GET AND (Headers.Authorization OR Body has access_token))
            $hasAuthHeader = $false
            $hasTokenInBody = $false
            
            if ($Request.Headers) {
                foreach ($headerKey in $Request.Headers.Keys) {
                    if (($headerKey -eq 'authorization' -or $headerKey -eq 'Authorization' -or $headerKey -eq 'AUTHORIZATION') -and 
                        $Request.Headers[$headerKey] -match '^Bearer\s+') {
                        $hasAuthHeader = $true
                        break
                    }
                }
            }
            
            # Check for access_token in body (both JSON and query string formats)
            if ($Request.Body) {
                if ($Request.Body -is [string] -and $Request.Body -like "*access_token=*") {
                    $hasTokenInBody = $true
                }
                elseif ($Request.Body -is [PSCustomObject] -or $Request.Body -is [hashtable]) {
                    $tokenParam = $BodyParams | Where-Object { $_.Key -eq 'access_token' }
                    if ($tokenParam -and -not [string]::IsNullOrWhiteSpace($tokenParam.Value)) {
                        $hasTokenInBody = $true
                    }
                }
            }
            
            if (($Request.Method -eq "GET" -and $hasAuthHeader) -or $hasTokenInBody) {
                # This is an authenticated request for log data
                Write-Host "This is an authenticated request for log data"
                Write-Host ($Request | Out-String)
                
                # Get Checkpoint URL from environment or use default
                $checkpointUrl = $env:CHECKPOINT_LOG_API_URL
                if ([string]::IsNullOrWhiteSpace($checkpointUrl)) {
                    $checkpointUrl = "https://cloudinfra-gw-us.portal.checkpoint.com/app/hec-api/v1.0/search/query"
                }
                
                # Extract additional parameters for Checkpoint API
                $additionalParams = @{}
                
                # Check for query parameters that should be passed to Checkpoint
                if ($Request.Query) {
                    $queryParams = @{}
                    $Request.Query.PSObject.Properties | ForEach-Object {
                        if ($_.Name -ne "code" -and $_.Name -ne "auto_fetch_logs" -and $_.Name -ne "autoFetchLogs") {
                            $queryParams[$_.Name] = $_.Value
                        }
                    }
                    if ($queryParams.Count -gt 0) {
                        $additionalParams.QueryParams = $queryParams
                    }
                }
                
                # Check for method override
                if ($Request.Method) {
                    $additionalParams.Method = $Request.Method
                }
                
                $LogDataResponse = Get-CheckpointLogData -Request $Request -CheckPointUrl $checkpointUrl -AdditionalParams $additionalParams
                
                Write-Host "LogData Response:"
                Write-Host ($LogDataResponse | ConvertTo-Json -Depth 10 | Out-String)
                $IsAuthenticatedRequest = $true
            }
            else {
                # This is an auth request
                $NewRequest = Rewrite-CheckPointAuthRequest -Request $OriginalRequest -BodyParams $BodyParams
            }
            break
        }
        "MicrosoftGraph" {
            $NewRequest = Rewrite-MicrosoftGraphAuthRequest -Request $OriginalRequest -BodyParams $BodyParams
            break
        }
        default {
            Write-Host "Unknown application: $Application"
        }
    }
    # Handle authentication request
    if ($NewRequest -and -not $IsAuthenticatedRequest) {
        Write-Host "Processing authentication request"
        $Response = $null
        $ResponseContent = $null
        
        try {
            switch ($Application) {
                "Checkpoint" {
                    $Response = Get-CheckPointAccessToken -NewRequest $NewRequest
                    Write-Host "Checkpoint Authentication Response:"
                    Write-Host "StatusCode: $($Response.StatusCode)"
                    Write-Host "StatusDescription: $($Response.StatusDescription)"
                    Write-Host "Content: $($Response.Content | ConvertTo-Json)"
                    
                    # Convert Content object to JSON string
                    if ($Response.Content -is [hashtable] -or $Response.Content -is [PSCustomObject]) {
                        $ResponseContent = $Response.Content | ConvertTo-Json -Compress
                    }
                    else {
                        $ResponseContent = $Response.Content
                    }
                    
                    $AuthResponse = $ResponseContent
                    $ResponseStatusCode = [HttpStatusCode]$Response.StatusCode
                    
                    # Check if we should auto-fetch log data
                    if ($AutoFetchLogs -and $Response.StatusCode -eq 200) {
                        Write-Host "Auto-fetch enabled, fetching log data after successful authentication"
                        
                        # Extract access_token and csrf from auth response
                        $authContent = $Response.Content
                        $accessToken = $authContent.access_token
                        $csrf = $authContent.csrf
                        
                        if ($accessToken) {
                            # Build a request object with the token for log data fetch
                            $logDataRequest = "" | Select-Object Headers, Body, Method, Query
                            $logDataRequest.Method = "GET"
                            $logDataRequest.Headers = @{}
                            $logDataRequest.Body = @{
                                access_token = $accessToken
                                token_type = "Bearer"
                            }
                            if ($csrf) {
                                $logDataRequest.Body.csrf = $csrf
                            }
                            $logDataRequest.Query = $Request.Query
                            
                            # Get Checkpoint URL from environment or use default
                            $checkpointUrl = $env:CHECKPOINT_LOG_API_URL
                            if ([string]::IsNullOrWhiteSpace($checkpointUrl)) {
                                $checkpointUrl = "https://cloudinfra-gw-us.portal.checkpoint.com/app/hec-api/v1.0/search/query"
                            }
                            
                            # Extract additional parameters for Checkpoint API
                            $additionalParams = @{}
                            if ($Request.Query) {
                                $queryParams = @{}
                                $Request.Query.PSObject.Properties | ForEach-Object {
                                    if ($_.Name -ne "code" -and $_.Name -ne "auto_fetch_logs" -and $_.Name -ne "autoFetchLogs") {
                                        $queryParams[$_.Name] = $_.Value
                                    }
                                }
                                if ($queryParams.Count -gt 0) {
                                    $additionalParams.QueryParams = $queryParams
                                }
                            }
                            
                            try {
                                $LogDataResponse = Get-CheckpointLogData -Request $logDataRequest -CheckPointUrl $checkpointUrl -AdditionalParams $additionalParams
                                Write-Host "Auto-fetched log data response received"
                            }
                            catch {
                                Write-Host "Error auto-fetching log data: $($_.Exception.Message)"
                                # Continue with auth response if log data fetch fails
                            }
                        }
                    }
                    
                    break
                }
                "MicrosoftGraph" {
                    $Response = Get-MicrosoftGraphAccessToken -NewRequest $NewRequest
                    Write-Host "Microsoft Graph Authentication Response:"
                    Write-Host "StatusCode: $($Response.StatusCode)"
                    Write-Host "StatusDescription: $($Response.StatusDescription)"
                    Write-Host "Content: $($Response.Content)"
                    
                    $ResponseContent = $Response.Content
                    $AuthResponse = $ResponseContent
                    $ResponseStatusCode = [HttpStatusCode]$Response.StatusCode
                    break
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "Error processing request: $errorMessage"
            if ($_.Exception.Response) {
                $ResponseStatusCode = [HttpStatusCode]$_.Exception.Response.StatusCode.value__
                try {
                    $errorStream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($errorStream)
                    $errorBody = $reader.ReadToEnd()
                    $AuthResponse = $errorBody
                }
                catch {
                    $AuthResponse = @{ error = $errorMessage } | ConvertTo-Json
                }
            }
            else {
                $ResponseStatusCode = [HttpStatusCode]::InternalServerError
                $AuthResponse = @{ error = $errorMessage } | ConvertTo-Json
            }
        }
    }
    elseif (-not $IsAuthenticatedRequest) {
        Write-Host "No valid request type identified"
    }
}
else {
    Write-Host "No application found in the request"
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
$statusCode = [HttpStatusCode]::OK
$ResponseBody = $null

# Prioritize log data response over auth response
if ($LogDataResponse) {
    $statusCode = [HttpStatusCode]$LogDataResponse.StatusCode
    
    # Convert response content to JSON string if it's an object
    if ($LogDataResponse.Content) {
        if ($LogDataResponse.Content -is [string]) {
            # Try to parse as JSON to validate, then return as string
            try {
                $parsed = $LogDataResponse.Content | ConvertFrom-Json
                $ResponseBody = $LogDataResponse.Content
            }
            catch {
                # Not JSON, return as-is
                $ResponseBody = $LogDataResponse.Content
            }
        }
        elseif ($LogDataResponse.Content -is [hashtable] -or $LogDataResponse.Content -is [PSCustomObject]) {
            $ResponseBody = $LogDataResponse.Content | ConvertTo-Json -Depth 10
        }
        else {
            $ResponseBody = $LogDataResponse.Content.ToString()
        }
    }
    else {
        $ResponseBody = $null
    }
    
    Write-Host "Returning log data response with status code: $statusCode"
}
elseif ($AuthResponse) {
    if ($ResponseStatusCode) {
        $statusCode = $ResponseStatusCode
    }
    
    # Ensure AuthResponse is a JSON string
    if ($AuthResponse -is [string]) {
        $ResponseBody = $AuthResponse
    }
    elseif ($AuthResponse -is [hashtable] -or $AuthResponse -is [PSCustomObject]) {
        $ResponseBody = $AuthResponse | ConvertTo-Json -Compress
    }
    else {
        $ResponseBody = $AuthResponse.ToString()
    }
    
    Write-Host "Returning auth response with status code: $statusCode"
}
else {
    # Default response
    $ResponseBody = "This HTTP triggered function executed successfully."
    Write-Host "Returning default response"
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $statusCode
        Body       = $ResponseBody
    })
