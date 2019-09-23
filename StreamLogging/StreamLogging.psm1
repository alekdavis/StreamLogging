<#
.SYNOPSIS
PowerShell module implementing logging to the console and/or text files using StreamWriter.

.LINK
https://github.com/alekdavis/StreamLogging
#>

#------------------------------[ IMPORTANT ]-------------------------------

<#
PLEASE MAKE SURE THAT THE SCRIPT STARTS WITH THE COMMENT HEADER ABOVE AND
THE HEADER IS FOLLOWED BY AT LEAST ONE BLANK LINE; OTHERWISE, GET-HELP AND
GETVERSION COMMANDS WILL NOT WORK.
#>

#------------------------[ RUN-TIME REQUIREMENTS ]-------------------------

#Requires -Version 4.0

#---------------------------[ MODULE VARIABLES ]---------------------------

# Log targets.
$TARGET_CONSOLE = "Console"
$TARGET_FILE    = "File"

# Log levels.
$LOGLEVEL_NONE    = "None"
$LOGLEVEL_ERROR   = "Error"
$LOGLEVEL_WARNING = "Warning"
$LOGLEVEL_INFO    = "Info"
$LOGLEVEL_DEBUG   = "Debug"

# Numeric values of log levels (lower number takes precedence).
$LogLevels = @{
    $LOGLEVEL_NONE    = 0;
    $LOGLEVEL_ERROR   = 1;
    $LOGLEVEL_WARNING = 2;
    $LOGLEVEL_INFO    = 3;
    $LOGLEVEL_DEBUG   = 4
}

# Loge level prefixes for log and error files.
$LogPrefixes = @{
    $LOGLEVEL_ERROR   = "ERROR";
    $LOGLEVEL_WARNING = "WARN ";
    $LOGLEVEL_INFO    = "INFO ";
    $LOGLEVEL_DEBUG   = "DEBUG"
}

# Log configuration settings.
$Config = [PSCustomObject]@{
    Initialized            = $false

    LogLevel               = $null

    Console                = $false
    File                   = $false
    ErrorFile              = $false

    FilePath               = $null
    ErrorFilePath          = $null

    Backup                 = $false
    Overwrite              = $false
    Append                 = $false

    WithLogLevel           = $false
    WithTimestamp          = $false

    TimestampFormat        = $null
    UtcTime                = $null

    TabSize                = 2

    BackgroundColor        = $null
    ForegroundColor        = $null
}

# Log stream writers.
$Stream = [PSCustomObject]@{
    LogFile   = $null
    ErrorFile = $null
}

# Console font and background colors.
# It would be nice to get colors dynamically, but this would break in
# PowerShell ISE because it uses 32-bit colors instead of 8-bit colors.

$COLOR_ERROR    = "Red"
$COLOR_WARNING  = "Yellow"
$COLOR_DEBUG    = "Gray"

$ForegroundColors = @{
    $LOGLEVEL_ERROR   = $COLOR_ERROR   # $Host.PrivateData.ErrorForegroundColor
    $LOGLEVEL_WARNING = $COLOR_WARNING # $Host.PrivateData.WarningForegroundColor
    $LOGLEVEL_INFO    = $null
    $LOGLEVEL_DEBUG   = $COLOR_DEBUG   # $Host.PrivateData.DebugForegroundColor
}

$BackgroundColors = @{
    $LOGLEVEL_ERROR   = $null # $Host.PrivateData.ErrorBackgroundColor
    $LOGLEVEL_WARNING = $null # $Host.PrivateData.WarningBackgroundColor
    $LOGLEVEL_INFO    = $null
    $LOGLEVEL_DEBUG   = $null # $Host.PrivateData.DebugBackgroundColor
}

# File extensions.
$LOGFILE_EXT_DEFAULT        = ".log"
$ERRFILE_EXT_DEFAULT        = ".err.log"
$BACKUP_EXT_DEFAULT         = ".txt"
$CONFIGFILE_EXT_DEFAULT     = ".json"
$CONFIGFILE_NAMEEXT_DEFAULT = ".StreamLogging" + $CONFIGFILE_EXT_DEFAULT

#---------------------------[ PRIVATE FUNCTIONS ]--------------------------

#--------------------------------------------------------------------------
# FormatLine
#   Formats line before it is written to the console or a file.
function FormatLine {
    [CmdletBinding()]
    param (
        [string]
        $line,

        [int]
        $indent,

        [string]
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        $logLevel,

        [string]
        [ValidateSet("Console", "File")]
        $logType
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    $indentPrefix   = "";
    $timePrefix     = "";
    $logLevelPrefix = "";
    $prefix         = "";

    # Set indent prefix.
    if ($indent -gt 0) {
        $space = " "
        $tab   = ""

        for ($i=0; $i -lt $Script:Config.TabSize; $i++) {
            $tab += $space
        }

        for ($i=0; $i -lt $indent; $i++) {
            $indentPrefix += $tab
        }
    }

    # When logging to file, set optional timestamp and log level prefixes.
    if ($logType -eq "File") {
        if ($Script:Config.WithTimestamp) {
            if ($Script:Config.UtcTime) {
                $timePrefix = ((Get-Date).
                    ToUniversalTime()).
                        ToString($Script:Config.TimestampFormat)
            }
            else {
                $timePrefix = (Get-Date).ToString($Script:Config.TimestampFormat)
            }
        }

        if ($Script:Config.WithLogLevel) {
            $logLevelPrefix = $Script:LogPrefixes[$logLevel]
        }
    }

    # Add separators between prefixes.
    if ($timePrefix) {
        $prefix = $timePrefix + ":"
    }

    if ($logLevelPrefix) {
        $prefix += ($logLevelPrefix + ":")
    }

    if ($prefix) {
        $prefix += (" " + $indentPrefix)
    }
    else {
        if ($indentPrefix) {
            $prefix = $indentPrefix
        }
    }

    return $prefix + $line
}

#--------------------------------------------------------------------------
# ImportConfigFile
#   Sets local variables of a caller to the values from a config file.
#   This function was adopted from:
#   https://www.powershellgallery.com/packages/ConfigFile
function ImportConfigFile {
    [CmdletBinding()]
    param (
        [string]
        $ConfigFile,

        [Hashtable]
        $DefaultParameters = $null
    )

    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (-not $PSBoundParameters.ContainsKey('Verbose'))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (-not $PSBoundParameters.ContainsKey('Debug'))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    # If config file was explicitly specified, make sure it exists.
    if ($ConfigFile) {
        if (!(Test-Path -Path $ConfigFile -PathType Leaf)) {

            # Given file does not exist. Try appending it to invoking script.
            $configFilePath = $null

            if ($PSCmdlet) {
                $configFilePath = $Script:MyInvocation.PSCommandPath + $ConfigFile
            }
            else {
                $configFilePath = $Script:PSCommandPath + $ConfigFile
            }

            if (!(Test-Path -Path $configFile -PathType Leaf)) {
                throw "Config file '" + $ConfigFile + "' is not found."
            }

            $ConfigFile = $configFilePath
        }
    }
    # If path is not specified, use the default (script + .json extension).
    else {
        # Default config file is named after running script with .json extension.
        if ($PSCmdlet) {
            # If this is in a module, get the module name and append it to script with
            # '.json' extension.
            $ext = "." + [io.path]::GetFileNameWithoutExtension($PSCommandPath)
            $ConfigFile = $Script:MyInvocation.PSCommandPath + $ext + $CONFIGFILE_EXT_DEFAULT
        }
        else {
            # If this is in a script, name must be hard coded.
            $ConfigFile = $Script:PSCommandPath + $CONFIGFILE_NAMEEXT_DEFAULT
        }

        # Default config file is optional.
        if (!(Test-Path -Path $ConfigFile -PathType Leaf)) {
            Write-Verbose "Config file '$ConfigFile' is not found."
            return
        }
    }

    $count = 0
    Write-Verbose "Loading config file '$ConfigFile'."

    # Process file.
    $jsonString = Get-Content $ConfigFile -Raw `
        -ErrorAction:SilentlyContinue -WarningAction:SilentlyContinue

    if (!$jsonString) {
        Write-Verbose "Config file is empty."
        return
    }

    Write-Verbose "Converting config file settings into a JSON object."
    $jsonObject = $jsonString | ConvertFrom-Json `
        -ErrorAction:SilentlyContinue -WarningAction:SilentlyContinue

    if (!$jsonObject) {
        Write-Verbose "Cannot convert config file settings into a JSON object."
        return
    }

    $strict = ($jsonObject._meta.strict -or $jsonObject.meta.strict)
    $prefix = $jsonObject._meta.prefix
    if (!$prefix) {
        $jsonObject.meta.prefix
    }
    if (!$prefix) {
        $prefix = "_"
    }

    # Process elements twice: first, literals, then the ones that require expansion.
    # Technically, when using the module, one pass would suffice, since the only
    # supported expandable values are environment variables (%%) or PowerShell
    # environment variables ($env:) and these can be resolved in a single pass.
    # But in case this function is copied into and used directly from a script
    # (not from a module), the second pass is needed in case a value references
    # a script variable. Again, keep in mind that script variable expansion is not
    # supported when using the module.
    for ($i=0; $i -lt 2; $i++) {
        $jsonObject.PSObject.Properties | ForEach-Object {

            # Copy properties to variables for readability.
            $hasValue   = $_.Value.hasValue
            $name       = $_.Name
            $value      = $null
            $value      = $_.Value.value

            # In ForEach-Object loops 'return' acts as 'continue' in  loops.
            if ($name.StartsWith($prefix)) {
                # Skip to next (yes, 'return' is the right statement here).
                return
            }

            # If 'hasValue' is explicitly set to 'false', ignore element.
            if ($hasValue -eq $false) {
                return
            }

            # Now, the 'hasValue' is either missing or is set to 'true'.

            # In the strict mode, 'hasValue' must be set to include the element.
            if ($strict -and ($null -eq $hasValue)) {
                return
            }

            # If 'hasValue' is not set and the value resolves to 'false', ignore it.
            if (($null -eq $hasValue) -and (!$value)) {
                return
            }

            # Check if parameter is specified on command line.
            if ($DefaultParameters) {
                if ($DefaultParameters.ContainsKey($name)) {
                    return
                }
            }

            # Okay, we must use the value.

            # The value must be expanded if it:
            # - is not marked as a literal,
            # - has either '%' or '$' character (not the $ end-of-line special character),
            # - is neither of PowerShell constants that has a '$' character in name
            #   ($true, $false, $null).
            if ((!$_.Value.literal) -and
                (($value -match "%") -or ($value -match "\$")) -and
                ($value -ne $true) -and
                ($value -ne $false) -and
                ($null -ne $value)) {

                # Skip on the first iteration in case it depends on the unread variable.
                if ($i -eq 0) {
                    $name = $null
                }
                # Process on second iteration.
                else {
                    if ($value -match "%") {

                        # Expand environment variable.
                        $value = [System.Environment]::ExpandEnvironmentVariables($value)
                    }
                    else {
                        # Expand PowerShell variable.
                        $value = $ExecutionContext.InvokeCommand.ExpandString($value)
                    }
                }
            }
            else {
                # Non-expandable variables have already been processed in the first iteration.
                if ($i -eq 1) {
                    $name = $null
                }
            }

            if ($name) {
                if ($count -eq 0) {
                    Write-Verbose "Setting variable(s):"
                }

                Write-Verbose "-$name '$value'"

                # Scope 1 is the scope of the function in the module that called this function.
                Set-Variable -Scope 1 -Name $name -Value $value -Force -Visibility Public

                $count++
            }
        }
    }

    if ($count -gt 0) {
        Write-Verbose "Done setting $count variable(s) from the config file."
    }
}

#--------------------------------------------------------------------------
# Initialize
#   Initializes log settings
function Initialize {
    [CmdletBinding()]
    param (
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($Script:Config.Initialized) {
        Write-Verbose "Resetting stream logging properties."
    }
    else {
        Write-Verbose "Setting stream logging properties."
    }

    $Script:Config.Initialized      = $false

    $Script:Config.LogLevel         = $null

    $Script:Config.Console          = $false
    $Script:Config.File             = $false
    $Script:Config.ErrorFile        = $false

    $Script:Config.FilePath         = $null
    $Script:Config.ErrorFilePath    = $null

    $Script:Config.Backup           = $false
    $Script:Config.Overwrite        = $false
    $Script:Config.Append           = $false

    $Script:Config.WithLogLevel     = $false
    $Script:Config.WithTimestamp    = $false

    $Script:Config.TimestampFormat  = $null
    $Script:Config.UtcTime          = $null

    $Script:Config.TabSize          = 2

    $Script:Config.BackgroundColor  = $null
    $Script:Config.ForegroundColor  = $null

    $Script:ForegroundColors = @{
        $LOGLEVEL_ERROR   = $COLOR_ERROR
        $LOGLEVEL_WARNING = $COLOR_WARNING
        $LOGLEVEL_INFO    = $null
        $LOGLEVEL_DEBUG   = $COLOR_DEBUG
    }

    $Script:BackgroundColors = @{
        $LOGLEVEL_ERROR   = $null
        $LOGLEVEL_WARNING = $null
        $LOGLEVEL_INFO    = $null
        $LOGLEVEL_DEBUG   = $null
    }

    if ($Script:Stream.LogFile) {
        Write-Verbose "Closing log file stream."
        try {
            $Script:Stream.LogFile.Dispose()
        }
        catch {
            Write-Verbose "Error closing log file stream:"
            Write-Verbose $_.Exception.Message
        }
        $Script:Stream.LogFile = $null
    }

    if ($Script:Stream.ErrorFile) {
        Write-Verbose "Closing error file stream."
        try {
            $Script:Stream.ErrorFile.Dispose()
        }
        catch {
            Write-Verbose "Error closing error file stream:"
            Write-Verbose $_.Exception.Message
        }
        $Script:Stream.ErrorFile = $null
    }
}

#--------------------------------------------------------------------------
# IsLoggableMessage
#   Checks if there is a valid message.
function IsLoggableMessage {
    [CmdletBinding()]
    param (
        [string]
        $message,

        [int]
        $indent
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if (($message -eq $null) -and ($indent -eq 0)) {
        return $false
    }

    return $true
}

#--------------------------------------------------------------------------
# IsLoggableToConsole
#   Checks if the message should be logged to the console.
function IsLoggableToConsole {
    [CmdletBinding()]
    param (
        [string]
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        $logLevel
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }
        if ($Script:Config.LogLevel -eq $LOGLEVEL_NONE) {
        return $false
    }

    if (!($Script:Config.Console)) {
        return $false
    }

    if ($Script:LogLevels[$logLevel] -gt $Script:LogLevels[$Script:Config.LogLevel]) {
        return $false
    }

    return $true
}

#--------------------------------------------------------------------------
# IsLoggableToFile
#   Checks if the message should be logged to a log or error file.
function IsLoggableToFile {
    [CmdletBinding()]
    param (
        [string]
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        $logLevel,

        [bool]
        $errFile = $false
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($Script:Config.LogLevel -eq $LOGLEVEL_NONE) {
        return $false
    }

    if ($Script:LogLevels[$logLevel] -gt $Script:LogLevels[$Script:Config.LogLevel]) {
        return $false
    }

    if ($errFile) {
        if ($logLevel -ne $LOGLEVEL_ERROR) {
            return $false
        }

        if (!($Script:Config.ErrorFile)) {
            return $false
        }

        return $true
    }

    if (!($Script:Config.File)) {
        return $false
    }

    return $true
}

#--------------------------------------------------------------------------
# LogToConsole
#   Writes log message to the console.
function LogToConsole {
    [CmdletBinding(DefaultParameterSetName="")]
    param (
        [string]
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        $logLevel,

        [string]
        $message,

        [int]
        $indent
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    # If background color was explicitly specified, use it;
    # otherwise, get it from hard coded configuration.
    if ($Script:Config.BackgroundColor) {
        $bgColor = $Script:Config.BackgroundColor
    }
    else {
        $bgColor = $Script:BackgroundColors[$logLevel]
    }

    # If foreground color was explicitly specified, use it;
    # otherwise, get it from hard coded configuration.
    if ($Script:Config.ForegroundColor) {
        $fontColor = $Script:Config.ForegroundColor
    }
    else {
        $fontColor = $Script:ForegroundColors[$logLevel]
    }

    # Only set non-null color values.
    $colorParams = @{}

    if ($fontColor) {
        $colorParams.Add("ForegroundColor", $fontColor)
    }

    if ($bgColor) {
        $colorParams.Add("BackgroundColor", $bgColor)
    }

    # Split text into separate lines.
    $lines = ($message -split '\r?\n')

    # Print each line.
    foreach ($line in $lines) {
        # But format the line first.
        $line = FormatLine $line $indent $logLevel $TARGET_CONSOLE

        Write-Host $line @colorParams
    }
}

#--------------------------------------------------------------------------
# LogToFile
#   Writes log message to the log or error file.
function LogToFile {
    [CmdletBinding()]
    param (
        [string]
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        $logLevel,

        [string]
        $message,

        [int]
        $indent,

        [bool]
        $errFile = $false
    )

    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    # If the file has not been open, yet, do it now.
    if ($errFile) {
        if (!($Script:Stream.ErrorFile)) {
            $Script:Stream.ErrorFile = OpenFile $Script:Config.ErrorFilePath $true
        }
    }
    else {
        if (!($Script:Stream.LogFile)) {
            $Script:Stream.LogFile = OpenFile $Script:Config.FilePath $false
        }
    }

    # Process text one line at a time.
    $lines = ($message -split '\r?\n')

    foreach ($line in $lines) {
        # Format line first.
        $line = FormatLine $line $indent $logLevel $TARGET_FILE

        # Write line to the appropriate file: log or error.
        if ($errFile) {
            if ($Script:Stream.ErrorFile) {
                $Script:Stream.ErrorFile.WriteLine($line)
                $Script:Stream.ErrorFile.Flush()
            }
        }
        else {
            if ($Script:Stream.LogFile) {
                $Script:Stream.LogFile.WriteLine($line)
                $Script:Stream.LogFile.Flush()
            }
        }
    }
}

#--------------------------------------------------------------------------
# OpenFile
#   Opens log or error file (backs up, appends or overwrites old file, if needed).
function OpenFile {
    [CmdletBinding()]
    param (
        [string]
        $filePath,

        [bool]
        $errFile = $false
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    # First, check if file already exists.
    if (Test-Path -Path $filePath -PathType Leaf) {
        Write-Verbose "File '$filePath' exists."

        # Append existing file.
        if ($Script:Config.Append) {
            Write-Verbose "Opening file '$filePath' for appending."
            return (New-Object -TypeName System.IO.StreamWriter $filePath, $true)
        }
        # Overwrite existing file.
        elseif ($Script:Config.Overwrite) {
            Write-Verbose "Overwriting file '$filePath'."
            return (New-Object -TypeName System.IO.StreamWriter `
                $filePath, $false, ([System.Text.Encoding]::UTF8))
        }
        # Back up existing file, and create a new one.
        else {
            $timeStamp  = $null
            $timeFormat = "yyyyMMddHHmmss"
            $fileName   = $null
            $fileDir    = $null

            do {
                # If generated file already exists, sleep for a second.
                if ($timeStamp) {
                    Start-Sleep -s 1
                }

                # Generate timestamp based on local or UTC time.
                if ($Script:Config.UtcTime) {
                    $timeStamp = ((Get-Date).
                        ToUniversalTime()).
                            ToString($timeFormat)
                }
                else {
                    $timeStamp = (Get-Date).ToString($timeFormat)
                }

                # Build new filename with timestamp.
                $fileName = (Split-Path -Path $filePath -Leaf) + ".$timeStamp$BACKUP_EXT_DEFAULT"

                # Get path to the folder holding the file.
                $fileDir = Split-Path -Path $filePath -Parent

                # Repeat until we generate a name of a non-existent file.
            } while (Test-Path -Path (Join-Path $fileDir $fileName))

            Write-Verbose "Renaming file '$filePath' to '$fileName'."
            Rename-Item -Path $filePath -NewName $fileName | Out-Null
        }
    }

    # At this point, the file does not exist.

    # Get path to the folder holding the file.
    $fileDir = Split-Path -Path $filePath -Parent

    # Make sure the folder exists.
    if (!(Test-Path -Path $fileDir -PathType Container)) {
        Write-Verbose "Creating directory '$fileDir'."
        New-Item -Path $fileDir -ItemType Directory -Force | Out-Null
    }

    Write-Verbose "Creating file '$filePath'."
    return (New-Object -TypeName System.IO.StreamWriter `
        $filePath, $false, ([System.Text.Encoding]::UTF8))
}

#--------------------------------------------------------------------------
# WriteLog
#   Writes log entry to the console and/or log files.
function WriteLog {
    [CmdletBinding()]
    param (
        [string]
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        $logLevel,

        [string]
        $message,

        [int]
        $indent,

        [bool]
        $writeToConsole,

        [bool]
        $writeToFile
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if (!(IsLoggableMessage $message $indent)) {
        return
    }

    # Write message to the console.
    if ($writeToConsole -and (IsLoggableToConsole $logLevel)) {
        LogToConsole $logLevel $message $indent
    }

    # Write message to the log file.
    if ($writeToFile -and (IsLoggableToFile $logLevel $false)) {
        LogToFile $logLevel $message $indent $false
    }

    # Write message to the error file.
    if ($writeToFile -and (IsLoggableToFile $logLevel $true)) {
        LogToFile $logLevel $message $indent $true
    }
}

#---------------------------[ EXPORTED FUNCTIONS ]-------------------------

<#
.SYNOPSIS
Formats the path of a log or error file from the specified file parts following the standard naming conventions.

.DESCRIPTION
Use this function to tweak parts of the default log or error file. By default, a log file is named after the calling PowerShell script with the same path and an appropriate extension. For example, when invoked from 'C:\Scripts\MyScript.ps1', the default log and error file paths will be formatted as:

- C:\Scripts\MyScript.log
- C:\Scripts\MyScript.err.log

You can tell this function to use the same formatting algorithm but use your own custom values for path to the directory, name, or extension. Say, you want to follow the same naming convention, but have the file in a different directory, such as 'D:\Logs'. In this case, just pass the name of the custom directory, such as:

$logFilePath = Format-LogFilePath -Directory "D:\Logs"
$errFilePath = Format-LogFilePath -Directory "D:\Logs" -IsErrorFile

The generated paths will look like:

- D:\Logs\MyScript.log
- D:\Logs\MyScript.err.log

In a similar manner, you can customize, names of the files and/or their extensions.

.PARAMETER Directory
Specifies the custom directory path that will be used in the file path.

.PARAMETER Name
Specifies the custom file name (without extension) that will be used in the file path.

.PARAMETER Extension
Specifies the custom file extension that will be used in the file path.

.PARAMETER IsErrorFile
Indicates that the generated path will be for the error file. If not specified, the standard log file is assumed.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
$logFilePath = Format-LogFilePath -Directory "D:\Logs"
Generates path of the log file with the custom directory path.

.EXAMPLE
$errFilePath = Format-LogFilePath -Directory "D:\Logs" -IsErrorFile
Generates path of the error file with the custom directory path.

.EXAMPLE
$logFilePath = Format-LogFilePath -Name "$env:computername"
Generates path of the log file with the custom name.

.EXAMPLE
$errFilePath = Format-LogFilePath -Name "$env:computername" -IsErrorFile
Generates path of the error file with the custom name.

.EXAMPLE
$logFilePath = Format-LogFilePath -Extension ".txt"
Generates path of the log file with the custom extension.

.EXAMPLE
$errFilePath = Format-LogFilePath -Extension ".error" -IsErrorFile
Generates path of the error file with the custom extension.
#>
function Format-LogFilePath {
    [CmdletBinding()]
    param (
        [Alias("Dir", "Folder")]
        [string]
        $Directory,

        [string]
        $Name,

        [Alias("Ext")]
        [string]
        $Extension,

        [Alias("IsError", "ErrorFile", "Err")]
        [switch]
        $IsErrorFile
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    $path = $null

    if ($PSCmdlet) {
        $path = $MyInvocation.PSCommandPath
    }
    else {
        $path = $PSCommandPath
    }

    if (!($Directory)) {
        $Directory = Split-Path -Path $path -Parent
    }

    if (!($FileName)) {
        $FileName = [IO.Path]::GetFileNameWithoutExtension($path)
    }

    if (!($Extension)) {
        if ($IsErrorFile) {
            $Extension = $ERRFILE_EXT_DEFAULT
        }
        else {
            $Extension = $LOGFILE_EXT_DEFAULT
        }
    }

    return (Join-Path $Directory $FileName) + $Extension
}

<#
.SYNOPSIS
Returns serialized stream logging configuration settings.

.DESCRIPTION
Use this function if you need to display stream logging configuration settings.

.PARAMETER Xml
When set, the settings will be serialized as XML; otherwise, they will be serialized as JSON.

.PARAMETER Compress
When set, the settings will be serialized in a compact format.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
$logSettings = Get-LoggingConfig
Returns logging configuration settings formatted as an uncompressed JSON string.

.EXAMPLE
$logSettings = Get-LoggingConfig -Xml -Json
Returns logging configuration settings formatted as a compressed XML string.
#>
function Get-LoggingConfig {
    [CmdletBinding()]
    param (
        [switch]
        $Xml,

        [switch]
        $Compress
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($Xml) {
        if ($Compress) {
            return ($Script:Config | ConvertTo-Xml -Compress).Trim()
        }
        else {
            return ($Script:Config | ConvertTo-Xml).Trim()
        }
    }
    else {
        if ($Compress) {
            return ($Script:Config | ConvertTo-Json -Compress).Trim()
        }
        else {
            return ($Script:Config | ConvertTo-Json).Trim()
        }
    }

}

<#
.SYNOPSIS
Initializes stream logging.

.DESCRIPTION
Call this function to configure the StreamLogging module.

You can configure logging using the function parameters or a configuration file. You can specify the path to the configuration file via the '-ConfigFile' parameter or use the implicit default path which is named after the running script with the '.StreamLogging.json' extension. For example, if the path to the running script is 'D:\Scripts\MyScript.ps1' the default path to the stream logging configuration file would be 'D:\Scripts\MyScript.ps1.StreamLogging.json'.

The configuration file must be in the JSON format similar to the following:

{
    "LogLevel": { "value": "Debug" },
    "Console": { "value": true },
    "File": { "value": true },
    "ErrorFile": { "value": true },
    "FilePath": { "value": null },
    "ErrorFilePath": { "value": null },
    "Backup": { "value": null },
    "Overwrite": { "value": true },
    "Append": { "value": null },
    "WithTimestamp": { "value": true },
    "TimestampFormat": { "value": null },
    "UtcTime": { "value": true },
    "TabSize": { "value": 4 },
    "BackgroundColor": { "value": null },
    "BackgroundColorError": { "value": null },
    "BackgroundColorWarning": { "value": null },
    "BackgroundColorInfo": { "value": null },
    "BackgroundColorDebug": { "value": null },
    "ForegroundColor": { "value": null },
    "ForegroundColorError": { "value": null },
    "ForegroundColorWarning": { "value": null },
    "ForegroundColorInfo": { "value": null },
    "ForegroundColorDebug": { "value": "Green" }
}

You can find a more detailed example of the configuration file at https://github.com/alekdavis/StreamLogging. For details about the configuration file format, see https://github.com/alekdavis/ConfigFile.

The configuration file and its elements are optional. A command-line parameter has a higher precedence than the corresponding configuration file value, i.e. if the 'LogLevel' value in the configuration file is set to 'Warning', but the '-LogLevel' function parameter is set to 'Debug', then the log level will be set to 'Debug'.

Log levels are ranked from 1 (Error) to 4 (Debug). Setting log level means that all entries with the same or lower ranks will be logged. See the description of the 'LogLevel' parameter for details.

Log records can be written to the console and a log file. In addition, error and exception messages can be written to a separate error file. By default, log entries will be written to the console.

.PARAMETER LogLevel
Defines the maximum level at which the log entries must be written to the console or the log files. The following log level are supported:

- None    (0): Nothing will be logged.
- Error   (1): Only errors and exceptions will be logged.
- Warning (2): Warnings, errors, and exceptions will be logged.
- Info    (3): Informational messages will be logged along with warnings, errors, and exceptions.
- Debug   (4): Debug messages will be logged along with everything else.

.PARAMETER Console
When set, log entries will be written to the console. If neither the log target switches ('-Console', '-File', and '-ErrorFile') are specified, the '-Console' switch will be automatically turned on (unless the log level is set to 'None').

.PARAMETER File
When set, log entries will be written to a log file. This switch will be automatically turned on if the '-FilePath' parameter is set. If the '-FilePath' parameter is not specified, the default log file will be used (the file path will be named after the running script with the '.log' extension, such as 'C:\Script\MyScript.log' for the script 'C:\Script\MyScript.ps1'). The log file will be created only when the first log message is written to it (see the 'Write-Log' function and its derivatives).

.PARAMETER ErrorFile
When set, error and exception messages will be written to a special error file. This switch will be automatically turned on if the '-ErrorFilePath' parameter is set. If the '-ErrorFilePath' parameter is not specified, the default error file will be used (the file path will be named after the running script with the '.err.log' extension, such as 'C:\Script\MyScript.err.log' for the script 'C:\Script\MyScript.ps1'). The error file will be created only when the first error or exception message is written to it (see the 'Write-Log' function and its derivatives).

.PARAMETER FilePath
Defines the path to the log file. If not specified, the log file path will be set to the path of the running script, only with the '.log' extension. For example, if the path of the running script is 'C:\Scripts\MyScript.ps1', the default log file path will be 'C:\Scripts\MyScript.log'. You can use the 'Format-LogFilePath' function to customize parts of the log file path. If the '-FilePath' explicitly set, the '-File' switch will be turned on.

.PARAMETER ErrorFilePath
Defines the path to the error file to which error and exception message will be copied. If not specified, the error file path will be set to the path of the running script, only with the '.err.log' extension. For example, if the path of the running script is 'C:\Scripts\MyScript.ps1', the default error file path will be 'C:\Scripts\MyScript.err.log'. You can use the 'Format-LogFilePath' function to customize parts of the error file path.

.PARAMETER Backup
When set, the existing log and error files will be backed up (the backed up will contain a timestamp in the file names). This is the default mode (when neither of the old file handling modes is specified).

.PARAMETER Overwrite
When set, the existing log and error files will be overwritten.

.PARAMETER Append
When set, the existing log and error files will be appended.

.PARAMETER WithLogLevel
When set, all messages written to the log and error files (but not to the console) will include their log levels.

.PARAMETER WithTimestamp
When set, all messages written to the log and error files (but not to the console) will include timestamps.

.PARAMETER TimeStampFormat
Defines the timestamp format that will be used when the '-WithTimestamp' switch is turned on. The default timestamp format includes year, month, day, hour, minute, and second, such as '2019-10-23 14:45:28'. For formatting details, see .NET documentation ('Custom date and time format strings' at https://docs.microsoft.com/en-us/dotnet/standard/base-types/custom-date-and-time-format-strings).

.PARAMETER UtcTime
When set, timestamps will contain time in Universal Time Coordinates (UTC, or GMT).

.PARAMETER TabSize
Defines the number of indent spaces. The default value is 2.

.PARAMETER BackgroundColor
Specifies the console background color. When defined, it will be applied to the log entries of all log levels. You can specify individual colors for each log level using the configuration file (see the description of the '-ConfigFile' parameter).

.PARAMETER ForegroundColor
Specifies the console font color. When defined, it will be applied to the log entries of all log levels. You can specify individual colors for each log level using the configuration file (see the description of the '-ConfigFile' parameter).

.PARAMETER ConfigFile
Specifies the path or extension of the logging configuration file described above (in the DESCRIPTION section). If no file is found under the path, the parameter value will be appended to the path of the running script. For example, if you set the value to '.Log.config', for the running script with path 'D:\Scripts\MyScript.ps1', the config file path will be formatted as 'D:\Scripts\MyScript.ps1.Log.config'. The default config file path is named after the running script with the '.StreamLogging.json' extension (in our example, it would point to 'D:\Scripts\MyScript.ps1.StreamLogging.json'). If the 'ConfigFile' value is explicitly set, the file with the same path (or extension) must exist. If this parameter is not specified, the file located at the default path is optional.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
Start-Logging
Initializes stream logging to the default settings or the settings specified in the default configuration file. Unless the default settings are overwritten, log messages will be written to the console and the log level will be set to 'Info'.

.EXAMPLE
Start-Logging -LogLevel None
Turns logging off (no log messages will be written anywhere).

.EXAMPLE
Start-Logging -LogLevel Debug -Console -ErrorFile -WithTime -UtcTime
Sets logging for all log levels to be sent to the console. All error and exception messages will be also copied to the default error file. Log entries written to the error file will be prefixed with the timestamps reflecting Universal (GMT) time.

.EXAMPLE
Start-Logging -ConfigFile ".log.json"
Initializes stream logging using the settings from the configuration file named after the running script with the '.log.json' extension.

.EXAMPLE
Start-Logging -ConfigFile ".log.json" -LogLevel Debug
Initializes stream logging using the settings from the configuration file named after the running script with the '.log.json' extension and the 'Debug' log level (regardless of the log level specified in the configuration file).
#>
function Start-Logging {
    [CmdletBinding(DefaultParameterSetName="default")]
    param (
        [ValidateSet("None", "Error", "Warning", "Info", "Debug")]
        [string]
        $LogLevel = "Info",

        [switch]
        $Console,

        [switch]
        $File,

        [switch]
        $ErrorFile,

        [parameter(Position=0)]
        [string]
        $FilePath,

        [parameter(Position=1)]
        [string]
        $ErrorFilePath,

        [Parameter(ParameterSetName="Backup")]
        [switch]
        $Backup,

        [Parameter(ParameterSetName="Overwrite")]
        [switch]
        $Overwrite,

        [Parameter(ParameterSetName="Append")]
        [switch]
        $Append,

        [switch]
        $WithLogLevel,

        [switch]
        $WithTimestamp,

        [string]
        $TimestampFormat = "yyyy-MM-dd HH:mm:ss",

        [Alias("Utc", "Gmt", "GmtTime", "UniversalTime")]
        [switch]
        $UtcTime,

        [ValidateRange(1, 8)]
        [int]
        $TabSize = 2,

        [ValidateSet(
            "Black",
            "DarkBlue",
            "DarkGreen",
            "DarkCyan",
            "DarkRed",
            "DarkMagenta",
            "DarkYellow",
            "Gray",
            "DarkGray",
            "Blue",
            "Green",
            "Cyan",
            "Red",
            "Magenta",
            "Yellow",
            "White")]
        [Alias("Background")]
        [string]
        $BackgroundColor,

        [ValidateSet(
            "Black",
            "DarkBlue",
            "DarkGreen",
            "DarkCyan",
            "DarkRed",
            "DarkMagenta",
            "DarkYellow",
            "Gray",
            "DarkGray",
            "Blue",
            "Green",
            "Cyan",
            "Red",
            "Magenta",
            "Yellow",
            "White")]
        [Alias("Foreground")]
        [string]
        $ForegroundColor,

        [Alias("Config")]
        [string]
        $ConfigFile
    )

    # Colors can be imported from the config file.
    [string]$ForegroundColorError    = $null
    [string]$ForegroundColorWarning  = $null
    [string]$ForegroundColorInfo     = $null
    [string]$ForegroundColorDebug    = $null

    [string]$BackgroundColorError   = $null
    [string]$BackgroundColorWarning = $null
    [string]$BackgroundColorInfo    = $null
    [string]$BackgroundColorDebug   = $null

    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    Write-Verbose "Starting stream logging."

    # Clear all log config settings.
    Initialize

    # Import settings from a config file (if it exists).
    ImportConfigFile $ConfigFile $PSBoundParameters

    # NOTE: $Script scope is the scope of this module (not the calling script).

    # First, check log level. If it is 'None', we're done.
    if ($LogLevel -eq $LOGLEVEL_NONE) {
        Write-Verbose "Logging is turned OFF."
        $Script:Config.LogLevel = $LOGLEVEL_NONE
        return
    }
    $Script:Config.LogLevel = $LogLevel

    # If neither log targets nor file paths were specified, log to console only.
    if (!($Console) -and !($File) -and !($ErrorFile) -and
        !($FilePath) -and !($ErrorFilePath)) {

        $Script:Config.Console = $true
    }
    else {
        # If log targets were not specified, but file paths were,
        # set appropriate targets.
        if (!($Console) -and !($File) -and !($ErrorFile)) {
            if ($FilePath) {
                $File = $true
            }

            if ($ErrorFilePath) {
                $ErrorFile = $true
            }
        }

        $Script:Config.Console  = [bool]$Console
        $Script:Config.File     = [bool]$File
        $Script:Config.ErrorFile= [bool]$ErrorFile
    }

    # If log file is a log target, but we do not have the path,
    # set the default path.
    if ($File -and !($FilePath)) {
        $path = $null

        if ($PSCmdlet) {
            $path = $MyInvocation.PSCommandPath
        }
        else {
            $path = $PSCommandPath
        }

        $fileDir = Split-Path -Path $path -Parent
        $fileName = [IO.Path]::GetFileNameWithoutExtension($path)

        $FilePath = Format-LogFilePath -Dir $fileDir -Name $fileName
    }
    $Script:Config.FilePath = $FilePath

    # If error file is a log target, but we do not have the path,
    # set the default path.
    if ($ErrorFile -and !($ErrorFilePath)) {
        $path = $null

        if ($PSCmdlet) {
            $path = $MyInvocation.PSCommandPath
        }
        else {
            $path = $PSCommandPath
        }

        $fileDir = Split-Path -Path $path -Parent
        $fileName = [IO.Path]::GetFileNameWithoutExtension($path)

        $ErrorFilePath = Format-LogFilePath -Dir $fileDir -Name $fileName -IsErrorFile
    }
    $Script:Config.ErrorFilePath = $ErrorFilePath

    # Define what we'll do with existing files (back them up by default).
    if (!($Backup) -and !($Overwrite) -and !($Append)) {
        $Backup = $true
    }

    if ($Backup) {
        $Script:Config.Backup = $true
    }
    elseif ($Overwrite) {
        $Script:Config.Overwrite = $true
    }
    else {
        $Script:Config.Append = $true
    }

    $Script:Config.UtcTime = [bool]$UtcTime

    $Script:Config.TabSize         = $TabSize
    $Script:Config.WithLogLevel    = $WithLogLevel
    $Script:Config.WithTimestamp   = $WithTimestamp
    $Script:Config.TimestampFormat = $TimestampFormat

    # Verify timestamp.
    if ($TimestampFormat) {
        try {
            if ((Get-Date).ToString($TimestampFormat)) {
                $Script:Config.TimestampFormat = $TimestampFormat
            }
            else {
                throw "Cannot convert timestamp to string."
            }
        }
        catch {
            throw (New-Object System.Exception(
                "Invalid timestamp format: " + $TimestampFormat + ".",
                $_.Exception))
        }
    }

    # Define console background colors.
    if ($BackgroundColor) {
        $Script:Config.BackgroundColor = $BackgroundColor
    }
    else {
        $Colors = @{
            $LOGLEVEL_ERROR   = $BackgroundColorError
            $LOGLEVEL_WARNING = $BackgroundColorWarning
            $LOGLEVEL_INFO    = $BackgroundColorInfo
            $LOGLEVEL_DEBUG   = $BackgroundColorDebug
        }

        foreach ($key in $Colors.Keys) {
            $color = $Colors[$key]

            if ($color) {
                $Script:BackgroundColors[$key] = $color
            }
        }
    }

    # Define console foreground colors.
    if ($ForegroundColor) {
        # If a single color is specified, apply it to everything.
        $Script:Config.ForegroundColor = $ForegroundColor
    }
    else {
        $Colors = @{
            $LOGLEVEL_ERROR   = $ForegroundColorError
            $LOGLEVEL_WARNING = $ForegroundColorWarning
            $LOGLEVEL_INFO    = $ForegroundColorInfo
            $LOGLEVEL_DEBUG   = $ForegroundColorDebug
        }

        foreach ($key in $Colors.Keys) {
            $color = $Colors[$key]

            if ($color) {
                $Script:ForegroundColors[$key] = $color
            }
        }
    }

    $Script:Config.Initialized = $true
}

<#
.SYNOPSIS
Resets stream logging and releases all resources.

.DESCRIPTION
Call this function to perform a cleanup after the last log entry was written. It will close any open file streams and reset configuration settings to the default values. If you are only logging to the console, you do not need to call this function (altough, it would not hurt).

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
Stop-Logging
Closes log files (if any were previously open) and resets all logging settings to the defaults.
#>
function Stop-Logging {
    [CmdletBinding()]
    param (
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    Write-Verbose "Stopping stream logging."

    Initialize
}

<#
.SYNOPSIS
Writes a log entry.

.DESCRIPTION
Call this function or one of its shortcuts (Write-LogDebug, Write-LogError, Write-LogException, Write-LogInfo, Write-LogWarning) to write a log message or exception info to the configured log targets: console, log file, and/or error file.

Before calling this function, make sure that 'Start-Logging' is called to initialize log settings.

.PARAMETER LogLevel
Defines the log level of the current message. If not specified, the default log level will be 'Info', unless exception is being logged, in which case, it will be 'Error'.

.PARAMETER Message
Defines the message that will being logged. The value can be passed via this parameter or as a piped input.

.PARAMETER Errors
Used for logging exceptions. By default, it will hold the '$Global:Error' (a collection of session errors) object, but you can also pass it (or any of its derivatives, such as the '$_' object in the exception catch block, although, in this case, you'll lose inner exceptions) explicitly. You can use it to pass your own error or collection of errors, but make sure that each object either is or contains a valid exception (in the latter case, an exception must be set to the 'Exception' property).

.PARAMETER Indent
Specifies by how many tabs (see the 'Start-Logging' function description) the log entry must be indented. The default value is 0 (zero). The maximum value is 255.

.PARAMETER NoConsole
When set, the log entry will not be written to the console even if the console was set as a log target by the 'Start-Logging' function.

.PARAMETER NoFile
When set, the log entry will not be written to the log and/or error files even if they were set as the log targets by the 'Start-Logging' function.

.PARAMETER Raw
When set, the value of the '-Errors' parameter will be written using the default serialization (by default, only error messages from all errors in the collection will be logged without any additional exception data).

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
A string message object ('Message' parameter) can be piped into this function.

.OUTPUTS
None.

.EXAMPLE
Write-Log "Hello, info!"
Writes an informational message to the configured log targets.

.EXAMPLE
Write-Log -Message "Hello, info!"
Writes an informational message to the configured log targets.

.EXAMPLE
Write-Log -Message "Hello, info!" -LogLevel Info
Writes an informational message to the configured log targets.

.EXAMPLE
"Hello, info!" | Write-Log -NoFile
Writes an informational message to the configured log targets, except the log file, even if it is one of the configured log targets.

.EXAMPLE
Write-Log "Hello, debug!" -LogLevel Debug -Indent 1
Writes an debug message to the configured log targets indenting it by one tab.

.EXAMPLE
Write-Log "Hello, warning!" -LogLevel Warning -NoConsole
Writes an warning message to the configured log targets, except the console, even if it is one of the configured log targets.

.EXAMPLE
Write-Log "Hello, error!" -LogLevel Error
Writes an error message to the configured log targets. If the '$Global:Error' object contains errors, they will be logged as well (only exception messages from the error object will be logged).

.EXAMPLE
"Hello, error!" | Write-Log -LogLevel Error -Errors $Global:Error -Raw
Writes an error message to the configured log targets along with the explicitly passed errors from the '$Global:Error' object. The errors will be serialized using the default formatting.
#>
function Write-Log {
    [CmdletBinding(DefaultParameterSetName="Message")]
    param (
        [ValidateSet("Error", "Warning", "Info", "Debug")]
        [string]
        $LogLevel = "Info",

        [Parameter(Position=0,ValueFromPipeline)]
        [string]
        $Message,

        [object]
        $Errors = $Global:Error,

        [Parameter(Position=1)]
        [ValidateRange(0, 255)]
        [int]
        $Indent = 0,

        [switch]
        $NoConsole,

        [switch]
        $NoFile,

        [switch]
        $Raw
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($NoConsole -and $NoFile) {
        return
    }

    $args = @{}

    # Set common parameters.
    if ($Indent -gt 0)  { $args.Add("Indent", $Indent) }
    if ($NoConsole)     { $args.Add("NoConsole", $true) }
    if ($NoFile)        { $args.Add("NoFile", $true) }

    switch ($LogLevel) {
        $LOGLEVEL_ERROR {
            # If we have a message, log it first.
            if ($Message) {
                $args.Add("Message", $Message)
                Write-LogError @args
                $args.Remove("Message")
            }

            # If we have session errors, log them as well.
            if ($Errors) {
                $args.Add("Errors", $Errors)
                if ($Raw) {
                    $args.Add("Raw", $true)
                }
                Write-LogException @args
            }
            break;
        }
        $LOGLEVEL_WARNING {
            if ($Message) {
                Write-LogWarning -Message $Message @args
            }
            break
        }
        $LOGLEVEL_INFO {
            if ($Message) {
                Write-LogInfo -Message $Message @args
            }
            break
        }
        default {
            if ($Message) {
                Write-LogDebug -Message $Message @args
            }
            break
        }
    }
}

<#
.SYNOPSIS
Writes a debug log entry.

.DESCRIPTION
Call this function to write a debug message to the configured log targets: console or log file.

Before calling this function, make sure that 'Start-Logging' is called to initialize log settings.

.PARAMETER Message
Defines the message that will being logged. The value can be passed via this parameter or as a piped input.

.PARAMETER Indent
Specifies by how many tabs (see the 'Start-Logging' function description) the log entry must be indented. The default value is 0 (zero). The maximum value is 255.

.PARAMETER NoConsole
When set, the log entry will not be written to the console even if the console was set as a log target by the 'Start-Logging' function.

.PARAMETER NoFile
When set, the log entry will not be written to the log file even if it was set as a log target by the 'Start-Logging' function.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
A string message object ('Message' parameter) can be piped into this function.

.OUTPUTS
None.

.EXAMPLE
Write-LogDebug "Hello, debug!"
Writes a debug message to the configured log targets.

.EXAMPLE
"Hello, debug!" | Write-LogDebug
Writes a debug message to the configured log targets.

.EXAMPLE
Write-LogDebug "Hello, debug!" -Indent 1
Writes a debug message to the configured log targets indenting it by one tab.

.EXAMPLE
Write-LogDebug "Hello, debug!" -NoFile
Writes a debug message to the console only, assuming that it is a configured log target.

.EXAMPLE
"Hello, debug!" | Write-LogDebug -NoConsole
Writes a debug message to the log file only, assuming that it is a configured log target.
#>
function Write-LogDebug {
    [CmdletBinding()]
    param (
        [Parameter(Position=0,ValueFromPipeline)]
        [string]
        $Message,

        [Parameter(Position=1)]
        [ValidateRange(0, 255)]
        [int]
        $Indent = 0,

        [Parameter(Position=2)]
        [switch]
        $NoConsole,

        [Parameter(Position=3)]
        [switch]
        $NoFile
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($NoConsole -and $NoFile) {
        return
    }

    WriteLog $LOGLEVEL_DEBUG $Message $Indent (-not $NoConsole) (-not $NoFile)
}

<#
.SYNOPSIS
Writes an error log entry.

.DESCRIPTION
Call this function to write an error message to the configured log targets: console, log file, and/or error file.

Before calling this function, make sure that 'Start-Logging' is called to initialize log settings.

.PARAMETER Message
Defines the message that will being logged. The value can be passed via this parameter or as a piped input.

.PARAMETER Indent
Specifies by how many tabs (see the 'Start-Logging' function description) the log entry must be indented. The default value is 0 (zero). The maximum value is 255.

.PARAMETER NoConsole
When set, the log entry will not be written to the console even if the console was set as a log target by the 'Start-Logging' function.

.PARAMETER NoFile
When set, the log entry will not be written to the log and/or error files even if they were set as the log targets by the 'Start-Logging' function.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
A string message object ('Message' parameter) can be piped into this function.

.OUTPUTS
None.

.EXAMPLE
Write-LogError "Hello, error!"
Writes an error message to the configured log targets.

.EXAMPLE
"Hello, error!" | Write-LogError
Writes an error message to the configured log targets.

.EXAMPLE
Write-LogError "Hello, error!" -Indent 1
Writes an error message to the configured log targets indenting it by one tab.

.EXAMPLE
Write-LogError "Hello, error!" -NoFile
Writes an error message to the console only, assuming that it is a configured log target.

.EXAMPLE
"Hello, error!" | Write-LogError -NoConsole
Writes an error message to the log and error files only, assuming that they are configured as the log targets.
#>
function Write-LogError {
    [CmdletBinding()]
    param (
        [Parameter(Position=0,ValueFromPipeline)]
        [string]
        $Message,

        [Parameter(Position=1)]
        [ValidateRange(0, 255)]
        [int]
        $Indent = 0,

        [Parameter(Position=2)]
        [switch]
        $NoConsole,

        [Parameter(Position=3)]
        [switch]
        $NoFile
    )
    if ($NoConsole -and $NoFile) {
        return
    }
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    WriteLog $LOGLEVEL_ERROR $Message $Indent (-not $NoConsole) (-not $NoFile)
}

<#
.SYNOPSIS
Writes a log entry from the information in the error object.

.DESCRIPTION
Call this function to write an error message to the configured log targets: console, log file, and/or error file.

Before calling this function, make sure that 'Start-Logging' is called to initialize log settings.

.PARAMETER Errors
If not explicitly set, this parameter will hold the value of the '$Global:Error' object. You can use it to pass your own error or collection of errors, but make sure that each object either is or contains a valid exception (in the latter case, an exception must be set to the 'Exception' property). The value can be passed via this parameter or as a piped input.

.PARAMETER Indent
Specifies by how many tabs (see the 'Start-Logging' function description) the log entry must be indented. The default value is 0 (zero). The maximum value is 255.

.PARAMETER NoConsole
When set, the log entry will not be written to the console even if the console was set as a log target by the 'Start-Logging' function.

.PARAMETER NoFile
When set, the log entry will not be written to the log and/or error files even if they were set as the log targets by the 'Start-Logging' function.

.PARAMETER Raw
When set, the value of the '-Errors' parameter will be written using the default serialization (by default, only error messages from all errors in the collection will be logged without any additional exception data).

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
An error collection object ('Errors' parameter) can be piped into this function.

.OUTPUTS
None.

.EXAMPLE
Write-LogException
Writes error messages from the '$Global:Error' collection to the configured log targets.

.EXAMPLE
Write-LogException -Errors $Global:Error
Writes error messages from the '$Global:Error' collection to the configured log targets.

.EXAMPLE
$Global:Error | Write-LogException -Raw
Writes error info from the '$Global:Error' collection to the configured log targets using the default error serialization.

.EXAMPLE
Write-LogException -Indent 1
Writes error messages from the '$Global:Error' collection to the configured log targets indenting them by one tab.

.EXAMPLE
Write-LogException -NoFile
Writes error messages from the '$Global:Error' collection to the console only, assuming that it is a configured log target.

.EXAMPLE
"Hello, error!" | Write-LogError -NoConsole
Writes error messages from the '$Global:Error' collection to the log and error files only, assuming that they are configured as the log targets.
#>
function Write-LogException {
    [CmdletBinding()]
    param (
        [Parameter(Position=0,ValueFromPipeline)]
        [object]
        $Errors = $Global:Error,

        [Parameter(Position=1)]
        [ValidateRange(0, 255)]
        [int]
        $Indent = 0,

        [Parameter(Position=2)]
        [switch]
        $NoConsole,

        [Parameter(Position=3)]
        [switch]
        $NoFile,

        [Parameter(Position=4)]
        [switch]
        $Raw
    )
    if ($NoConsole -and $NoFile) {
        return
    }
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    $message = $null

    if ($Raw) {
        $message = ($Errors | Out-String).Trim()

        if ($message) {
            Write-LogError $message $Indent $NoConsole $NoFile
        }
    }
    else {
        if ($Errors.Count) {
            foreach ($err in $Errors) {
                $message = $null;

                # Try getting error from the global $Errors object.
                if ($err.Exception -and $err.Exception.Message) {
                    $message = ($err.Exception.Message).Trim()
                }
                # Or maybe it is an exception object already.
                elseif ($err.Message) {
                    $message = ($err.Exception.Message).Trim()
                }
                # Forget it.
                else {
                    $message = $err.ToString().Trim()
                }

                if ($message) {
                    Write-LogError -Message $message $Indent $NoConsole $NoFile
                }
            }
        }
        else {
            # Try getting error from the global $Errors object.
            if ($Errors.Exception -and $Errors.Exception.Message) {
                $message = ($Errors.Exception.Message).Trim()
            }
            # Or maybe it is an exception object already.
            elseif ($Errors.Message) {
                $message = ($Errors.Exception.Message).Trim()
            }
            # Forget it.
            else {
                $message = $Errors.ToString().Trim()
            }

            if ($message) {
                Write-LogError -Message $message $Indent $NoConsole
            }
        }
    }
}

<#
.SYNOPSIS
Writes an informational log entry.

.DESCRIPTION
Call this function to write an informational message to the configured log targets: console or log file.

Before calling this function, make sure that 'Start-Logging' is called to initialize log settings.

.PARAMETER Message
Defines the message that will being logged. The value can be passed via this parameter or as a piped input.

.PARAMETER Indent
Specifies by how many tabs (see the 'Start-Logging' function description) the log entry must be indented. The default value is 0 (zero). The maximum value is 255.

.PARAMETER NoConsole
When set, the log entry will not be written to the console even if the console was set as a log target by the 'Start-Logging' function.

.PARAMETER NoFile
When set, the log entry will not be written to the log file even if it was set as a log target by the 'Start-Logging' function.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
A string message object ('Message' parameter) can be piped into this function.

.OUTPUTS
None.

.EXAMPLE
Write-LogInfo "Hello, info!"
Writes an informational message to the configured log targets.

.EXAMPLE
"Hello, info!" | Write-LogInfo
Writes an informational message to the configured log targets.

.EXAMPLE
Write-LogInfo "Hello, info!" -Indent 1
Writes an informational message to the configured log targets indenting it by one tab.

.EXAMPLE
Write-LogInfo "Hello, info!" -NoFile
Writes an informational message to the console only, assuming that it is a configured log target.

.EXAMPLE
"Hello, info!" | Write-LogInfo -NoConsole
Writes an informational message to the log file only, assuming that it is a configured log target.
#>
function Write-LogInfo {
    [CmdletBinding()]
    param (
        [Parameter(Position=0,ValueFromPipeline)]
        [string]
        $Message,

        [Parameter(Position=1)]
        [ValidateRange(0, 255)]
        [int]
        $Indent = 0,

        [Parameter(Position=2)]
        [switch]
        $NoConsole,

        [Parameter(Position=3)]
        [switch]
        $NoFile
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($NoConsole -and $NoFile) {
        return
    }

    WriteLog $LOGLEVEL_INFO $Message $Indent (-not $NoConsole) (-not $NoFile)
}

<#
.SYNOPSIS
Writes a warning log entry.

.DESCRIPTION
Call this function to write a warning message to the configured log targets: console or log file.

Before calling this function, make sure that 'Start-Logging' is called to initialize log settings.

.PARAMETER Message
Defines the message that will being logged. The value can be passed via this parameter or as a piped input.

.PARAMETER Indent
Specifies by how many tabs (see the 'Start-Logging' function description) the log entry must be indented. The default value is 0 (zero). The maximum value is 255.

.PARAMETER NoConsole
When set, the log entry will not be written to the console even if the console was set as a log target by the 'Start-Logging' function.

.PARAMETER NoFile
When set, the log entry will not be written to the log file even if it was set as a log target by the 'Start-Logging' function.

.LINK
https://github.com/alekdavis/StreamLogging

.INPUTS
A string message object ('Message' parameter) can be piped into this function.

.OUTPUTS
None.

.EXAMPLE
Write-LogWarning "Hello, warning!"
Writes a warning message to the configured log targets.

.EXAMPLE
"Hello, warning!" | Write-LogWarning
Writes a warning message to the configured log targets.

.EXAMPLE
Write-LogWarning "Hello, warning!" -Indent 1
Writes a warning message to the configured log targets indenting it by one tab.

.EXAMPLE
Write-LogWarning "Hello, warning!" -NoFile
Writes a warning message to the console only, assuming that it is a configured log target.

.EXAMPLE
"Hello, warning!" | Write-LogWarning -NoConsole
Writes a warning message to the log file only, assuming that it is a configured log target.
#>
function Write-LogWarning {
    [CmdletBinding()]
    param (
        [Parameter(Position=0,ValueFromPipeline)]
        [string]
        $Message,

        [Parameter(Position=1)]
        [ValidateRange(0, 255)]
        [int]
        $Indent = 0,

        [Parameter(Position=2)]
        [switch]
        $NoConsole,

        [Parameter(Position=3)]
        [switch]
        $NoFile
    )
    # Allow module to inherit '-Verbose' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Verbose')))) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    # Allow module to inherit '-Debug' flag.
    if (($PSCmdlet) -and (!($PSBoundParameters.ContainsKey('Debug')))) {
        $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference')
    }

    if ($NoConsole -and $NoFile) {
        return
    }

    WriteLog $LOGLEVEL_WARNING $Message $Indent (-not $NoConsole) (-not $NoFile)
}

Export-ModuleMember -Function "*-*"
