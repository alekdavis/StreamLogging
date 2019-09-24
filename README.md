# StreamLogging
PowerShell module implementing logging to the console and/or text files using StreamWriter.

## Introduction
Most (if not all) available PowerShell logging modules are not designed for efficiency. They may have many nice features, but when it comes to logging to text files, they all make calls that work like this:

1. Open text file.
2. Read the file to the end.
3. Write message to the file.
4. Close the file.

This may not be a big deal, but as your log file grows, your script performance will have to pay a performance penalty. If you are not willing to tolerate performance degradation caused by the logging calls, consider using this module.

## Overview
As the name implies, the `StreamLogging` module uses the standard .NET [StreaWriter class](https://docs.microsoft.com/en-us/dotnet/api/system.io.streamwriter) to implement logging. Instead of opening and closing the file every time the script needs to write a message, it keeps the stream open until logging is complete.

### Configuration
You can define the log configuration settings using the `Start-Logging` function. The function initializes log settings using the explicitly specified parameter or an optional configuration file (function parameters always take precedence). The default configuration file must be located in the same folder as the calling script and named after it with the `.StreamLogging.json` extension (you can adjust the extension or specify the whole path via the `-ConfigFile` parameter). A sample configuration file is included. You can also check a working sample at the [PowerShell script template repository](https://github.com/alekdavis/PowerShellScriptTemplate).

#### Log targets
The `StreamLogging` module can write to the console and/or a text file. It can also copy errors to a dedicated error file. You can define the log targets using the `-Console`, `-File`, and `-ErrorFile` switches. (The swithes and parameters identified in the __Configuration__ section are applied once during log initialization.)

##### Console
Console is the default log target (you do not need to use the `-Console` switch unless you set the file switches). When writing to the console, the module uses different colors to identify message log levels. You can force the console output to use the same colors via the `-ForegroundColor` and `-BackgroundColor` parameters (you can also reassign different colors to the log levels via the configuration file).

##### Files
The default log and error files are created in the same folder as the running script and have the same name and `.log` and `.err.log` extensions). You can specify your own log and error file paths or customize the parts of the default file paths using the `Format-LogFilePath` method. By default, before a new log file gets created, an old log file (with the same name) will be backed up (with a timestamp appended to the file name). You can also append new log entries to the existing files or simply overwrite them using the `-Append` or `-Overwrite` switches.

#### Log levels
`StreamLogging` supports the following log levels:

- `None`: Logging is turned off.
- `Error`: Only errors and exceptions are logged.
- `Warnings`: Warnings and errors are logged.
- `Info`: Informational messsages are logged along with warnings and errors.
- `Debug`: Debug messages are loged along with everything else.

#### Prefixes
When logging entries to the files, you can include timestamps and/or log levels via the `-WithTimestamp` and/or `-WithLogLevel` switches. By default, timestamps will reflect local time, but you can also use Universal time if you set the `-UtcTime` switch.

### Log entries
Once you initialize the log settings, you can start writing log entries to the specified targets: console and/or files. Normally, you would log string messages (assigned log levels), but you can also log error information from the global `$Error` object (default) or your custom exception (you will need to pass it explicitly).

#### Indentation
You can indent a log entry by setting the `-Indent` parameter to a positive number identifying the number of tabs (tab size is configurable).

#### Targets
When writing log entries, you can force the module to skip writing to the console or files even if they are set ups as logging targets using the `-NoConsole` and `-NoFile` switches.

## Usage
The `StreamLogging` module exposes the following functions:

### Format-LogPath
Allows you to customize parts of the default log or error file paths. The default log file are created in the same folder as the calling script with the same name and the `.log` and `.err.log` extensions. For example, for the script path `C:\Scripts\MyScipt.ps1`, the default log and error file paths would be `C:\Scripts\MyScipt.log` and `C:\Scripts\MyScipt.err.log` respectively. Say, you want to use the default names and extensions but place the file in the `D:\Logs` folder. This is how you generate the file paths:

```PowerShell
$logFilePath = Format-LogPath -Directory "D:\Logs"                # -> D:\Logs\MyScipt.log
$errFilePath = Format-LogPath -Directory "D:\Logs" -IsErrorFile   # -> D:\Logs\MyScipt.err.log
```

### Get-LoggingConfig

Returns logging configuration settings in a JSON or an XML format (in case you want to verify or print them). Notice  that the returned configuration does not reflect console font and background colors assigned to different log levels. To return result in a compact form, use the `-Compress` switch:

```PowerShell
$logConfigJson = Get-LoggingConfig -Compress
$logConfigXML  = Get-LoggingConfig -Compress
```

### Start-Logging

Initializes log settings (but does not create the log or error files until the first entry is written). By default, the initialization function will configure logging to write informational messages, warnings, and errors the console. You can adjust the setting by passing them to the `Start-Logging` function explicitly, or define them in the configuration file (command-line parameters have higher precedence than the configuration file values). The configuration file is not required but you may find it handy.

If you do not specify the configuration file, the module will look for the default file; otherwise, it will try to use the `-ConfigFile` parameter value as a file path and, if it does not find one, it will append the value to the script name and try it one more time (see the __Configuration__ section).

Here are a few examples of log initialization calls:

```PowerShell
Start-Logging
```
Initializes default log settings or use whatever settings are configured in the default configuration file if one exists.

```PowerShell
Start-Logging -ConfigFile ".Log.config"
```
Initializes log settings using the custom configuration file with path formatted by appending `.Log.config` to the path of the running script.

```PowerShell
Start-Logging -ConfigFile "D:\Common\LogConfig.json"
```
Initializes log settings using the custom configuration file with the `D:\Common\LogConfig.json` path.

```PowerShell
Start-Logging -ConfigFile "D:\Common\LogConfig.json" -LogLevel Debug -WithLogLevel -WithTimestamp -UtcTime
```
Initializes log settings using the custom configuration file with the `D:\Common\LogConfig.json` path, but sets the log level to `Debug`, and add prefix with the UTC timestamp and message log level to each line written to the log and/or error files.

### Stop-Logging

Closes open files and resets log settings. If you are logging to files, make sure you call this function before your script exits:

```PowerShell
Stop-Logging
```

### Write-Log

Writes a log entry of the specified log level (`Info` is the default) to the log targets. You can also use it to log an error object. Hera are a few examples of how you can invoke the `Write-Log` function:

```PowerShell
"Hello, info!" | Write-Log
Write-Log "Hello, info!"
Write-Log "Hello, debug" -LogLevel Debug -Indent 1
Write-Log -Error -NoConsole -Raw
Write-Log -Error "Hello, error"
Write-Log -LogLevel Warning "Hello, warning"
Write-Log -LogLevel Debug "Hello, debug!" -NoFile
```

### Write-LogDebug

Writes a debug message to the log targets, e.g.:

```PowerShell
"Hello, debug!" | Write-LogDebug
Write-LogDebug "Hello, debug!" -Indent 1
Write-LogDebug -Message "Hello, debug!" -NoFile
```

### Write-LogError

Writes an error message to the log targets, e.g.:

```PowerShell
"Hello, error!" | Write-LogError
Write-LogError "Hello, error!" -Indent 1
Write-LogError -Message "Hello, error!" -NoFile
```

### Write-LogException

Writes error information from the global `$Error` object or a custom exception to the log targets:

```PowerShell
Write-LogException
Write-LogException Raw
Write-LogException $Error
$Error | Write-Exception -Raw
```

### Write-LogInfo

Writes an informational message to the log targets, e.g.:

```PowerShell
"Hello, info!" | Write-LogInfo
Write-LogInfo "Hello, info!" -Indent 1
Write-LogInfo -Message "Hello, info!" -NoFile
```

### Write-LogWarning

Writes a warning to the log targets, e.g.:

```PowerShell
"Hello, warning!" | Write-LogWarning
Write-LogWarning "Hello, warning!" -Indent 1
Write-LogWarning -Message "Hello, warning!" -NoFile
```

## Sample
For a more complete example illustrating how to use the `StreamLogging` module, see the [sample script](https://github.com/alekdavis/PowerShellScriptTemplate).
