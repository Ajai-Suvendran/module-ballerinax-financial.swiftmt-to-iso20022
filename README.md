# Ballerina SWIFT MT to ISO 20022 Data Mapper Library

## Overview

The DataMapper Library is a comprehensive toolkit designed to convert SWIFT MT FIN messages into ISO 20022 XML within Ballerina applications. It simplifies the process of mapping SWIFT MT fields to their corresponding ISO 20022 elements, leveraging predefined records and parsers from the SWIFT MT and ISO 20022 libraries. This enables developers to seamlessly convert financial messages from the flat, text-based SWIFT format into the structured ISO 20022 XML standard, ensuring accurate and efficient data conversion.

## Supported Conversions

- SWIFT MT 1XX Category to ISO 20022
- SWIFT MT 2XX Category to ISO 20022
- SWIFT MT 9XX Category to ISO 20022
- SWIFT MT nXX Category to ISO 20022

## Usage

### Conversion of SWIFT fin message to ISO 20022 Xml Standard

```ballerina
import ballerina/io;
import ballerinax/financial.swiftmtToIso20022 as mtToMx;

public function main() returns error? {
    string finMessage = string `{1:F01CHASUS33AXXX0000000000}
{2:I900CRESCHZZXXXXN}
{4:
:20:C11126A1378
:21:5482ABC
:25:9-9876543
:32A:090123USD233530,
-}`;
    io:println(mtToMx:toIso20022Xml(finMessage));
}
```

## Report issues

To report bugs, request new features, start new discussions, view project boards, etc., go to
the [Ballerina library parent repository](https://github.com/ballerina-platform/ballerina-library).

## Useful Links

- Chat live with us via our [Discord server](https://discord.gg/ballerinalang).
- Post all technical questions on Stack Overflow with the [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
