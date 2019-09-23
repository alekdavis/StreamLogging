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

### Log targets
The `StreamLogging` module can write to the console and/or a text file. It can also copy errors to a dedicated error file. The default log and error files are created in the same folder as the running script and have the same name and `.log` and `.err.log` extensions). You can specify your own log and error file paths or customize the parts of the default file paths using the `Format-LogFilePath` method.

### Log levels
`StreamLogging` supports the following log levels:

- `None`: Logging is turned off.
- `Error`: Only errors and exceptions are logged.
- `Warnings`: Warnings and errors are logged.
- `Info`: Informational messsages are logged along with warnings and errors.
- `Debug`: Debug messages are loged along with everything else.

### Configuring logging
You can define the log configuration settings using the `Start-StreamLogging` function. The function initializes log settings using the explicitly specified parameter or an optional configuration file (function parameters always take precedence). The default configuration file must be located in the same folder as the calling script and named after it with the `.StreamLogging.json` extension (you can adjust the extension or specify the whole path via the `-ConfigFile` parameter).
