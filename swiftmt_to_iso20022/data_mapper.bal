// Copyright (c) 2023, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/data.xmldata;
import ballerina/uuid;
import ballerinax/financial.iso20022.cash_management as camtIsoRecord;
import ballerinax/financial.iso20022.payment_initiation as painIsoRecord;
import ballerinax/financial.iso20022.payments_clearing_and_settlement as pacsIsoRecord;
import ballerinax/financial.swift.mt as swiftmt;

# Converts a SWIFT message in string format to its corresponding ISO 20022 XML format.
#
# The function uses a map of transformation functions corresponding to different SWIFT MT message types 
# and applies the appropriate transformation based on the parsed message type.
#
# + finMessage - The SWIFT message string that needs to be transformed to ISO 20022 XML.
# + return - Returns the transformed ISO 20022 XML or an error if the transformation fails.
public isolated function toIso20022Xml(string finMessage) returns xml|error {
    record {} customizedMessage = check swiftmt:parseSwiftMt(finMessage);
    if customizedMessage is swiftmt:MT104Message {
        return getMT104TransformFunction(customizedMessage);
    }
    if customizedMessage is swiftmt:MT107Message {
        return getMT107TransformFunction(customizedMessage);
    }
    if customizedMessage is swiftmt:MTn96Message {
        return getMTn96TransformFunction(customizedMessage);
    }
    xml swiftMessageXml = check xmldata:toXml(customizedMessage);
    string messageType = (swiftMessageXml/**/<messageType>).data();
    string validationFlag = (swiftMessageXml/**/<ValidationFlag>/<value>).data();
    if validationFlag.length() > 0 {
        isolated function func = transformFunctionMap.get(messageType + validationFlag);
        return xmldata:toXml(check function:call(func, customizedMessage).ensureType(), {textFieldName: "content"});
    }
    isolated function func = transformFunctionMap.get(messageType);
    return xmldata:toXml(check function:call(func, customizedMessage).ensureType(), {textFieldName: "content"});
}

# Transforms the given SWIFT MT101 message to its corresponding ISO 20022 Pain.001 format.
#
# This function extracts various fields from the SWIFT MT101 message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT101 message as a record value.
# + return - Returns the transformed ISO 20022 `Pain001Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT101(swiftmt:MT101Message message) returns painIsoRecord:Pain001Document|error => {
    CstmrCdtTrfInitn: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            InitgPty: {
                Id: {
                    OrgId: {
                        AnyBIC: message.block4.MT50C?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifier(message.block4.MT50L?.PrtyIdn)
                            }
                        ]
                    }
                }
            },
            FwdgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        PmtInf: check getPaymentInformation(message.block4, message.block3)
    }
};

# Extracts payment information from the provided MT101 message and maps it to an array of ISO 20022 PaymentInstruction44 records.
#
# This function iterates over the transactions in the SWIFT MT101 message and retrieves details such as debtor, creditor,
# instructed amount, exchange rate, and intermediary agents. These details are then structured in ISO 20022 format.
#
# + block4 - The parsed block4 of MT101 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT101 SWIFT message containing end to end id.
# + return - Returns an array of PaymentInstruction44 records or an error if an issue occurs while fetching information.
isolated function getPaymentInformation(swiftmt:MT101Block4 block4, swiftmt:Block3? block3) returns painIsoRecord:PaymentInstruction44[]|error {
    painIsoRecord:PaymentInstruction44[] pmtInfArray = [];
    foreach swiftmt:MT101Transaction transaxion in block4.Transaction {
        swiftmt:MT50F? ordgCstm50F = <swiftmt:MT50F?>getMT101RepeatingFields(block4, transaxion.MT50F, "50F");
        swiftmt:MT50G? ordgCstm50G = <swiftmt:MT50G?>getMT101RepeatingFields(block4, transaxion.MT50G, "50G");
        swiftmt:MT50H? ordgCstm50H = <swiftmt:MT50H?>getMT101RepeatingFields(block4, transaxion.MT50H, "50H");
        swiftmt:MT52A? accWthInstn52A = <swiftmt:MT52A?>getMT101RepeatingFields(block4, transaxion.MT52A, "52A");
        swiftmt:MT52C? accWthInstn52C = <swiftmt:MT52C?>getMT101RepeatingFields(block4, transaxion.MT52C, "52C");

        pmtInfArray.push({
            PmtInfId: block4.MT20.msgId.content,
            CdtTrfTxInf: [
                {
                    Amt: {
                        InstdAmt: {
                            ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                                ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(transaxion.MT32B, transaxion.MT33B),
                                Ccy: transaxion.MT32B.Ccy.content
                            }
                        }
                    },
                    PmtId: {
                        EndToEndId: getEndToEndId(block4.MT21R?.Ref?.content, transaxion.MT70?.Nrtv?.content, transaxion.MT21.Ref.content),
                        InstrId: block4.MT20.msgId.content,
                        UETR: block3?.NdToNdTxRef?.value
                    },
                    XchgRateInf: {
                        XchgRate: check convertToDecimal(transaxion.MT36?.Rt)
                    },
                    Cdtr: {
                        Id: {
                            OrgId: {
                                AnyBIC: transaxion.MT59A?.IdnCd?.content
                            }
                        },
                        Nm: getName(transaxion.MT59F?.Nm, transaxion.MT59?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(transaxion.MT59F?.AdrsLine, transaxion.MT59?.AdrsLine),
                            Ctry: getCountryAndTown(transaxion.MT59F?.CntyNTw)[0],
                            TwnNm: getCountryAndTown(transaxion.MT59F?.CntyNTw)[1]
                        }
                    },
                    CdtrAcct: {
                        Id: {
                            IBAN: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc, acc3 = transaxion.MT59F?.Acc)[0],
                            Othr: {
                                Id: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc, acc3 = transaxion.MT59F?.Acc)[1],
                                SchmeNm: {
                                    Cd: getSchemaCode(transaxion.MT59A?.Acc, transaxion.MT59?.Acc, transaxion.MT59F?.Acc)
                                }
                            }
                        }
                    },
                    CdtrAgt: {
                        FinInstnId: {
                            BICFI: transaxion.MT57A?.IdnCd?.content,
                            LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn, transaxion.MT57C?.PrtyIdn, transaxion.MT57D?.PrtyIdn),
                            Nm: getName(transaxion.MT57D?.Nm),
                            PstlAdr: {
                                AdrLine: getAddressLine(transaxion.MT57D?.AdrsLine)
                            }
                        }
                    },
                    IntrmyAgt1: {
                        FinInstnId: {
                            BICFI: transaxion.MT56A?.IdnCd?.content,
                            LEI: getPartyIdentifier(transaxion.MT56A?.PrtyIdn, transaxion.MT56C?.PrtyIdn, transaxion.MT56D?.PrtyIdn),
                            Nm: getName(transaxion.MT56D?.Nm),
                            PstlAdr: {
                                AdrLine: getAddressLine(transaxion.MT56D?.AdrsLine)
                            }
                        }
                    },
                    InstrForDbtrAgt: {
                        Cd: getMT101InstructionCode(transaxion.MT23E, 1)[0],
                        InstrInf: getMT101InstructionCode(transaxion.MT23E, 1)[1]
                    },
                    InstrForCdtrAgt: [
                        {
                            Cd: getMT101InstructionCode(transaxion.MT23E, 2)[0],
                            InstrInf: getMT101InstructionCode(transaxion.MT23E, 2)[1]
                        }
                    ],
                    RgltryRptg: getRegulatoryReporting(transaxion.MT77B?.Nrtv?.content),
                    RmtInf: {Ustrd: [getRemmitanceInformation(transaxion.MT70?.Nrtv?.content)], Strd: []}
                }
            ],
            PmtTpInf: {
                SvcLvl: [
                    {
                        Cd: getMT101InstructionCode(transaxion.MT23E, 3)[0]
                    }
                ],
                CtgyPurp: {
                    Cd: getMT101InstructionCode(transaxion.MT23E, 4)[0]
                }
            },
            DbtrAcct: {
                Id: {
                    IBAN: getAccountId(validateAccountNumber(ordgCstm50G?.Acc, acc2 = ordgCstm50H?.Acc)[0], getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[1]),
                    Othr: {
                        Id: getAccountId(validateAccountNumber(ordgCstm50G?.Acc, acc2 = ordgCstm50H?.Acc)[1], getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[2]),
                        SchmeNm: {
                            Cd: getSchemaCode(ordgCstm50G?.Acc, ordgCstm50H?.Acc, prtyIdn1 = ordgCstm50F?.PrtyIdn)
                        }
                    }
                }
            },
            ReqdExctnDt: {
                Dt: convertToISOStandardDate(block4.MT30.Dt),
                DtTm: ""
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: accWthInstn52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(accWthInstn52A?.PrtyIdn, accWthInstn52C?.PrtyIdn)
                }
            },
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: ordgCstm50G?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[0],
                                SchmeNm: {
                                    Cd: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[3]
                                },
                                Issr: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[4]
                            }
                        ]
                    }
                },
                Nm: getName(ordgCstm50F?.Nm, ordgCstm50H?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(ordgCstm50F?.AdrsLine, ordgCstm50H?.AdrsLine),
                    Ctry: getCountryAndTown(ordgCstm50F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(ordgCstm50F?.CntyNTw)[1]
                }
            },
            PmtMtd: "TRF",
            ChrgBr: check getDetailsChargesCd(transaxion.MT71A.Cd).ensureType(painIsoRecord:ChargeBearerType1Code),
            ChrgsAcct: {
                Id: {
                    IBAN: validateAccountNumber(transaxion.MT25A?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(transaxion.MT25A?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(transaxion.MT25A?.Acc)
                        }
                    }
                }
            }
        }
        );
    }
    return pmtInfArray;
}

# Transforms the given SWIFT MT102STP message to its corresponding ISO 20022 Pacs.008 format.
#
# This function extracts various fields from the SWIFT MT102STP message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT102STP message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs008Document` structure.
# An error is returned if there is any failure transforming the SWIFT message to ISO 20022 format.
isolated function transformMT102STP(swiftmt:MT102STPMessage message) returns pacsIsoRecord:Pacs008Document|error => {
    FIToFICstmrCdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn)[0]
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getAccountId(validateAccountNumber(message.block4.MT53C?.Acc)[0], getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn)[1]),
                        Othr: {
                            Id: getAccountId(validateAccountNumber(message.block4.MT53C?.Acc)[1], getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn)[2]),
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT53C?.Acc, prtyIdn1 = message.block4.MT53A?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[0]
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check getTotalInterBankSettlementAmount(message.block4.MT19, message.block4.MT32A),
                    Ccy: message.block4.MT32A.Ccy.content
                }
            },
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: check getMT102STPCreditTransferTransactionInfo(message.block4, message.block3)
    }
};

# Processes an MT102 STP message and extracts credit transfer transaction information into ISO 20022 format.
# The function iterates over each transaction within the message, extracts relevant fields, and maps them 
# to the `CreditTransferTransaction64` ISO record structure. It handles various transaction fields such as 
# party identifiers, account information, currency amounts, and regulatory reporting.
#
# + block4 - The parsed block4 of MT102 STP SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT102 STP SWIFT message containing end to end id.
# + return - Returns an array of `CreditTransferTransaction64` records, each corresponding to a transaction 
# in the input message. If any error occurs during field extraction or conversion, an error will be returned.
isolated function getMT102STPCreditTransferTransactionInfo(swiftmt:MT102STPBlock4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:CreditTransferTransaction64[]|error {
    pacsIsoRecord:CreditTransferTransaction64[] cdtTrfTxInfArray = [];
    foreach swiftmt:MT102STPTransaction transaxion in block4.Transaction {
        swiftmt:MT26T? trnsTyp = <swiftmt:MT26T?>getMT102STPRepeatingFields(block4, transaxion.MT26T, "26T");
        swiftmt:MT36? xchgRate = <swiftmt:MT36?>getMT102STPRepeatingFields(block4, transaxion.MT36, "36");
        swiftmt:MT50F? ordgCstm50F = <swiftmt:MT50F?>getMT102STPRepeatingFields(block4, transaxion.MT50F, "50F");
        swiftmt:MT50A? ordgCstm50A = <swiftmt:MT50A?>getMT102STPRepeatingFields(block4, transaxion.MT50A, "50A");
        swiftmt:MT50K? ordgCstm50K = <swiftmt:MT50K?>getMT102STPRepeatingFields(block4, transaxion.MT50K, "50K");
        swiftmt:MT52A? ordgInstn52A = <swiftmt:MT52A?>getMT102STPRepeatingFields(block4, transaxion.MT52A, "52A");
        swiftmt:MT71A? dtlsChrgsCd = <swiftmt:MT71A?>getMT102STPRepeatingFields(block4, transaxion.MT71A, "71A");
        swiftmt:MT77B? rgltyRptg = <swiftmt:MT77B?>getMT102STPRepeatingFields(block4, transaxion.MT77B, "77B");

        cdtTrfTxInfArray.push({
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: transaxion.MT59A?.IdnCd?.content
                    }
                },
                Nm: getName(transaxion.MT59F?.Nm, transaxion.MT59?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(transaxion.MT59F?.AdrsLine, transaxion.MT59?.AdrsLine),
                    Ctry: getCountryAndTown(transaxion.MT59F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(transaxion.MT59F?.CntyNTw)[1]
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(transaxion.MT59F?.Acc, acc2 = transaxion.MT59?.Acc, acc3 = transaxion.MT59A?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(transaxion.MT59F?.Acc, acc2 = transaxion.MT59?.Acc, acc3 = transaxion.MT59A?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(transaxion.MT59F?.Acc, transaxion.MT59?.Acc, transaxion.MT59A?.Acc)
                        }
                    }
                }
            },
            CdtrAgt: {
                FinInstnId: {
                    BICFI: transaxion.MT57A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn)
                }
            },
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            PmtId: {
                EndToEndId: getEndToEndId(remmitanceInfo = transaxion.MT70?.Nrtv?.content, transactionId = transaxion.MT21.Ref.content),
                InstrId: block4.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value,
                TxId: transaxion.MT21.Ref.content
            },
            SttlmTmReq: {
                CLSTm: getTimeIndication(block4.MT13C)[0]
            },
            SttlmTmIndctn: {
                CdtDtTm: getTimeIndication(block4.MT13C)[1],
                DbtDtTm: getTimeIndication(block4.MT13C)[2]
            },
            IntrBkSttlmDt: convertToISOStandardDate(block4.MT32A.Dt),
            XchgRate: check convertToDecimal(xchgRate?.Rt),
            InstdAmt: {
                ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(transaxion.MT32B, transaxion.MT33B),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: ordgInstn52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(ordgInstn52A?.PrtyIdn)
                }
            },
            ChrgBr: check getDetailsChargesCd(dtlsChrgsCd?.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
            DbtrAcct: {
                Id: {
                    IBAN: getAccountId(validateAccountNumber(ordgCstm50A?.Acc, acc2 = ordgCstm50K?.Acc)[0], getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[1]),
                    Othr: {
                        Id: getAccountId(validateAccountNumber(ordgCstm50A?.Acc, acc2 = ordgCstm50K?.Acc)[1], getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[2]),
                        SchmeNm: {
                            Cd: getSchemaCode(ordgCstm50A?.Acc, ordgCstm50K?.Acc, prtyIdn1 = ordgCstm50F?.PrtyIdn)
                        }
                    }
                }
            },
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: ordgCstm50A?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[0],
                                SchmeNm: {
                                    Cd: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[3]
                                },
                                Issr: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[4]
                            }
                        ]
                    }
                },
                Nm: getName(ordgCstm50F?.Nm, ordgCstm50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(ordgCstm50F?.AdrsLine, ordgCstm50K?.AdrsLine),
                    Ctry: getCountryAndTown(ordgCstm50F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(ordgCstm50F?.CntyNTw)[1]
                }
            },
            PrvsInstgAgt1: {
                FinInstnId: {
                    BICFI: getMT1XXSenderToReceiverInformation(block4.MT72)[4],
                    Nm: getMT1XXSenderToReceiverInformation(block4.MT72)[5]
                }
            },
            ChrgsInf: check getChargesInformation(transaxion.MT71F, transaxion.MT71G),
            RgltryRptg: getRegulatoryReporting(rgltyRptg?.Nrtv?.content),
            RmtInf: {Ustrd: [getRemmitanceInformation(transaxion.MT70?.Nrtv?.content)], Strd: []},
            InstrForNxtAgt: [
                {
                    Cd: getMT1XXSenderToReceiverInformation(block4.MT72)[0],
                    InstrInf: getMT1XXSenderToReceiverInformation(block4.MT72)[1]
                }
            ],
            InstrForCdtrAgt: [
                {
                    Cd: getMT1XXSenderToReceiverInformation(block4.MT72)[2],
                    InstrInf: getMT1XXSenderToReceiverInformation(block4.MT72)[3]
                }
            ],
            Purp: {
                Cd: getMandatoryFields(trnsTyp?.Typ?.content)
            }
        });
    }
    return cdtTrfTxInfArray;
}

# Transforms the given SWIFT MT102 message to its corresponding ISO 20022 Pacs.008 format.
#
# This function extracts various fields from the SWIFT MT102 message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT102 message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs008Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT102(swiftmt:MT102Message message) returns pacsIsoRecord:Pacs008Document|error => {
    FIToFICstmrCdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn)[0]
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getAccountId(validateAccountNumber(message.block4.MT53C?.Acc)[0], getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn)[1]),
                        Othr: {
                            Id: getAccountId(validateAccountNumber(message.block4.MT53C?.Acc)[1], getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn)[2]),
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT53C?.Acc, prtyIdn1 = message.block4.MT53A?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[0]
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check getTotalInterBankSettlementAmount(message.block4.MT19, message.block4.MT32A),
                    Ccy: message.block4.MT32A.Ccy.content
                }
            },
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: check getMT102CreditTransferTransactionInfo(message.block4, message.block3)
    }
};

# Processes an MT102 message and extracts credit transfer transaction information into ISO 20022 format.
# The function iterates over each transaction within the message, extracts relevant fields, and maps them 
# to the `CreditTransferTransaction64` ISO record structure. It handles various transaction fields such as 
# party identifiers, account information, currency amounts, and regulatory reporting.
#
# + block4 - The parsed block4 of MT102 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT102 SWIFT message containing end to end id.
# + return - Returns an array of `CreditTransferTransaction64` records, each corresponding to a transaction 
# in the input message. If any error occurs during field extraction or conversion, an error will be returned.
isolated function getMT102CreditTransferTransactionInfo(swiftmt:MT102Block4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:CreditTransferTransaction64[]|error {
    pacsIsoRecord:CreditTransferTransaction64[] cdtTrfTxInfArray = [];
    foreach swiftmt:MT102Transaction transaxion in block4.Transaction {
        swiftmt:MT26T? trnsTyp = <swiftmt:MT26T?>getMT102RepeatingFields(block4, transaxion.MT26T, "26T");
        swiftmt:MT36? xchgRate = <swiftmt:MT36?>getMT102RepeatingFields(block4, transaxion.MT36, "36");
        swiftmt:MT50F? ordgCstm50F = <swiftmt:MT50F?>getMT102RepeatingFields(block4, transaxion.MT50F, "50F");
        swiftmt:MT50A? ordgCstm50A = <swiftmt:MT50A?>getMT102RepeatingFields(block4, transaxion.MT50A, "50A");
        swiftmt:MT50K? ordgCstm50K = <swiftmt:MT50K?>getMT102RepeatingFields(block4, transaxion.MT50K, "50K");
        swiftmt:MT52A? ordgInstn52A = <swiftmt:MT52A?>getMT102RepeatingFields(block4, transaxion.MT52A, "52A");
        swiftmt:MT52B? ordgInstn52B = <swiftmt:MT52B?>getMT102RepeatingFields(block4, transaxion.MT52B, "52B");
        swiftmt:MT52C? ordgInstn52C = <swiftmt:MT52C?>getMT102RepeatingFields(block4, transaxion.MT52C, "52C");
        swiftmt:MT71A? dtlsChrgsCd = <swiftmt:MT71A?>getMT102RepeatingFields(block4, transaxion.MT71A, "71A");
        swiftmt:MT77B? rgltyRptg = <swiftmt:MT77B?>getMT102RepeatingFields(block4, transaxion.MT77B, "77B");

        cdtTrfTxInfArray.push({
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: transaxion.MT59A?.IdnCd?.content
                    }
                },
                Nm: getName(transaxion.MT59F?.Nm, transaxion.MT59?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(transaxion.MT59F?.AdrsLine, transaxion.MT59?.AdrsLine),
                    Ctry: getCountryAndTown(transaxion.MT59F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(transaxion.MT59F?.CntyNTw)[1]
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(transaxion.MT59F?.Acc, acc2 = transaxion.MT59?.Acc, acc3 = transaxion.MT59A?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(transaxion.MT59F?.Acc, acc2 = transaxion.MT59?.Acc, acc3 = transaxion.MT59A?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(transaxion.MT59F?.Acc, transaxion.MT59?.Acc, transaxion.MT59A?.Acc)
                        }
                    }
                }
            },
            CdtrAgt: {
                FinInstnId: {
                    BICFI: transaxion.MT57A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn, transaxion.MT57C?.PrtyIdn)
                }
            },
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            PmtId: {
                EndToEndId: getEndToEndId(remmitanceInfo = transaxion.MT70?.Nrtv?.content, transactionId = transaxion.MT21.Ref.content),
                InstrId: block4.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value,
                TxId: transaxion.MT21.Ref.content
            },
            SttlmTmReq: {
                CLSTm: getTimeIndication(block4.MT13C)[0]
            },
            SttlmTmIndctn: {
                CdtDtTm: getTimeIndication(block4.MT13C)[1],
                DbtDtTm: getTimeIndication(block4.MT13C)[2]
            },
            IntrBkSttlmDt: convertToISOStandardDate(block4.MT32A.Dt),
            XchgRate: check convertToDecimal(xchgRate?.Rt),
            InstdAmt: {
                ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(transaxion.MT32B, transaxion.MT33B),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: ordgInstn52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(ordgInstn52A?.PrtyIdn, ordgInstn52B?.PrtyIdn, ordgInstn52C?.PrtyIdn)
                }
            },
            ChrgBr: check getDetailsChargesCd(dtlsChrgsCd?.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
            DbtrAcct: {
                Id: {
                    IBAN: getAccountId(validateAccountNumber(ordgCstm50A?.Acc, acc2 = ordgCstm50K?.Acc)[0], getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[1]),
                    Othr: {
                        Id: getAccountId(validateAccountNumber(ordgCstm50A?.Acc, acc2 = ordgCstm50K?.Acc)[1], getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[2]),
                        SchmeNm: {
                            Cd: getSchemaCode(ordgCstm50A?.Acc, ordgCstm50K?.Acc, prtyIdn1 = ordgCstm50F?.PrtyIdn)
                        }
                    }
                }
            },
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: ordgCstm50A?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[0],
                                SchmeNm: {
                                    Cd: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[3]
                                },
                                Issr: getPartyIdentifierOrAccount(ordgCstm50F?.PrtyIdn)[4]
                            }
                        ]
                    }
                },
                Nm: getName(ordgCstm50F?.Nm, ordgCstm50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(ordgCstm50F?.AdrsLine, ordgCstm50K?.AdrsLine),
                    Ctry: getCountryAndTown(ordgCstm50F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(ordgCstm50F?.CntyNTw)[1]
                }
            },
            PrvsInstgAgt1: {
                FinInstnId: {
                    BICFI: getMT1XXSenderToReceiverInformation(block4.MT72)[4],
                    Nm: getMT1XXSenderToReceiverInformation(block4.MT72)[5]
                }
            },
            ChrgsInf: check getChargesInformation(transaxion.MT71F, transaxion.MT71G),
            RgltryRptg: getRegulatoryReporting(rgltyRptg?.Nrtv?.content),
            RmtInf: {Ustrd: [getRemmitanceInformation(transaxion.MT70?.Nrtv?.content)], Strd: []},
            InstrForNxtAgt: [
                {
                    Cd: getMT1XXSenderToReceiverInformation(block4.MT72)[0],
                    InstrInf: getMT1XXSenderToReceiverInformation(block4.MT72)[1]
                }
            ],
            InstrForCdtrAgt: [
                {
                    Cd: getMT1XXSenderToReceiverInformation(block4.MT72)[2],
                    InstrInf: getMT1XXSenderToReceiverInformation(block4.MT72)[3]
                }
            ],
            Purp: {
                Cd: getMandatoryFields(trnsTyp?.Typ?.content)
            }
        });
    }
    return cdtTrfTxInfArray;
}

# Transforms the given SWIFT MT103REMIT message to its corresponding ISO 20022 Pacs.008 format.
#
# This function extracts various fields from the SWIFT MT103REMIT message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT103REMIT message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs008Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT103REMIT(swiftmt:MT103REMITMessage message) returns pacsIsoRecord:Pacs008Document|error => {
    FIToFICstmrCdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT54D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT54D?.AdrsLine)
                        }
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn, prtyIdn2 = message.block4.MT54B?.PrtyIdn, prtyIdn3 = message.block4.MT54D?.PrtyIdn)
                            }
                        }
                    }
                },
                ThrdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT55A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT55A?.PrtyIdn, message.block4.MT55B?.PrtyIdn, message.block4.MT55D?.PrtyIdn),
                        Nm: getName(message.block4.MT55D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT55D?.AdrsLine)
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                    Ccy: message.block4.MT32A.Ccy.content
                }
            },
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: [
            {
                Cdtr: {
                    Id: {
                        OrgId: {
                            AnyBIC: message.block4.MT59A?.IdnCd?.content
                        }
                    },
                    Nm: getName(message.block4.MT59F?.Nm, message.block4.MT59?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(message.block4.MT59F?.AdrsLine, message.block4.MT59?.AdrsLine),
                        Ctry: getCountryAndTown(message.block4.MT59F?.CntyNTw)[0],
                        TwnNm: getCountryAndTown(message.block4.MT59F?.CntyNTw)[1]
                    }
                },
                CdtrAcct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT59F?.Acc, acc2 = message.block4.MT59?.Acc, acc3 = message.block4.MT59A?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT59F?.Acc, acc2 = message.block4.MT59?.Acc, acc3 = message.block4.MT59A?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT59F?.Acc, message.block4.MT59?.Acc, message.block4.MT59A?.Acc)
                            }
                        }
                    }
                },
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn, message.block4.MT57B?.PrtyIdn, message.block4.MT57C?.PrtyIdn, message.block4.MT57D?.PrtyIdn),
                        Nm: getName(message.block4.MT57D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT57D?.AdrsLine)
                        }
                    }
                },
                IntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                PmtId: {
                    EndToEndId: "",
                    InstrId: message.block4.MT20.msgId.content,
                    UETR: message.block3?.NdToNdTxRef?.value
                },
                SttlmTmReq: {
                    CLSTm: getTimeIndication(message.block4.MT13C)[0]
                },
                SttlmTmIndctn: {
                    CdtDtTm: getTimeIndication(message.block4.MT13C)[1],
                    DbtDtTm: getTimeIndication(message.block4.MT13C)[2]
                },
                PmtTpInf: {
                    SvcLvl: [
                        {
                            Cd: message.block4.MT23B.Typ.content
                        }
                    ],
                    CtgyPurp: {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 4)[0]
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt),
                XchgRate: check convertToDecimal(message.block4.MT36?.Rt),
                InstdAmt: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                        ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(instrdAmnt = message.block4.MT33B, stlmntAmnt = message.block4.MT32A),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                DbtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT52A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                        Nm: getName(message.block4.MT52D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                        }
                    }
                },
                ChrgBr: check getDetailsChargesCd(message.block4.MT71A.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
                DbtrAcct: {
                    Id: {
                        IBAN: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[0], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[1]),
                        Othr: {
                            Id: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[1], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[2]),
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT50A?.Acc, message.block4.MT50K?.Acc, prtyIdn1 = message.block4.MT50F?.PrtyIdn)
                            }
                        }
                    }
                },
                Dbtr: {
                    Id: {
                        OrgId: {
                            AnyBIC: message.block4.MT50A?.IdnCd?.content
                        },
                        PrvtId: {
                            Othr: [
                                {
                                    Id: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[0],
                                    SchmeNm: {
                                        Cd: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[3]
                                    },
                                    Issr: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[4]
                                }
                            ]
                        }
                    },
                    Nm: getName(message.block4.MT50F?.Nm, message.block4.MT50K?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(message.block4.MT50F?.AdrsLine, message.block4.MT50K?.AdrsLine),
                        Ctry: getCountryAndTown(message.block4.MT50F?.CntyNTw)[0],
                        TwnNm: getCountryAndTown(message.block4.MT50F?.CntyNTw)[1]
                    }
                },
                PrvsInstgAgt1: {
                    FinInstnId: {
                        BICFI: getMT1XXSenderToReceiverInformation(message.block4.MT72)[4],
                        Nm: getMT1XXSenderToReceiverInformation(message.block4.MT72)[5]
                    }
                },
                IntrmyAgt1: {
                    FinInstnId: {
                        BICFI: message.block4.MT56A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56C?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                        Nm: getName(message.block4.MT56D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                        }
                    }
                },
                ChrgsInf: check getChargesInformation(message.block4.MT71F, message.block4.MT71G),
                RgltryRptg: getRegulatoryReporting(message.block4.MT77B?.Nrtv?.content),
                RmtInf: {Ustrd: [check getEnvelopeContent(message.block4.MT77T.EnvCntnt.content)[0].ensureType(string)], Strd: []},
                InstrForNxtAgt: [
                    {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 1)[0],
                        InstrInf: getMT103InstructionCode(message.block4.MT23E, 1)[1]
                    },
                    {
                        Cd: getMT1XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT1XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                InstrForCdtrAgt: [
                    {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 2)[0],
                        InstrInf: getMT103InstructionCode(message.block4.MT23E, 2)[1]
                    },
                    {
                        Cd: getMT1XXSenderToReceiverInformation(message.block4.MT72)[2],
                        InstrInf: getMT1XXSenderToReceiverInformation(message.block4.MT72)[3]
                    }
                ],
                Purp: {
                    Cd: getMandatoryFields(message.block4.MT26T?.Typ?.content)
                },
                SplmtryData: [
                    {
                        Envlp: {
                            Nrtv: getEnvelopeContent(message.block4.MT77T.EnvCntnt.content)[2],
                            XmlContent: getEnvelopeContent(message.block4.MT77T.EnvCntnt.content)[1]
                        }
                    }
                ]
            }
        ]
    }
};

# Transforms the given SWIFT MT103STP message to its corresponding ISO 20022 Pacs.008 format.
#
# This function extracts various fields from the SWIFT MT103STP message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT103STP message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs008Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT103STP(swiftmt:MT103STPMessage message) returns pacsIsoRecord:Pacs008Document|error => {
    FIToFICstmrCdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn)[0]
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[0]
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn)
                            }
                        }
                    }
                },
                ThrdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT55A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT55A?.PrtyIdn)
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                    Ccy: message.block4.MT32A.Ccy.content
                }
            },
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: [
            {
                Cdtr: {
                    Id: {
                        OrgId: {
                            AnyBIC: message.block4.MT59A?.IdnCd?.content
                        }
                    },
                    Nm: getName(message.block4.MT59F?.Nm, message.block4.MT59?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(message.block4.MT59F?.AdrsLine, message.block4.MT59?.AdrsLine),
                        Ctry: getCountryAndTown(message.block4.MT59F?.CntyNTw)[0],
                        TwnNm: getCountryAndTown(message.block4.MT59F?.CntyNTw)[1]
                    }
                },
                CdtrAcct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT59F?.Acc, acc2 = message.block4.MT59?.Acc, acc3 = message.block4.MT59A?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT59F?.Acc, acc2 = message.block4.MT59?.Acc, acc3 = message.block4.MT59A?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT59F?.Acc, message.block4.MT59?.Acc, message.block4.MT59A?.Acc)
                            }
                        }
                    }
                },
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn)
                    }
                },
                IntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                PmtId: {
                    EndToEndId: getEndToEndId(remmitanceInfo = message.block4.MT70?.Nrtv?.content),
                    InstrId: message.block4.MT20.msgId.content,
                    UETR: message.block3?.NdToNdTxRef?.value
                },
                SttlmTmReq: {
                    CLSTm: getTimeIndication(message.block4.MT13C)[0]
                },
                SttlmTmIndctn: {
                    CdtDtTm: getTimeIndication(message.block4.MT13C)[1],
                    DbtDtTm: getTimeIndication(message.block4.MT13C)[2]
                },
                PmtTpInf: {
                    SvcLvl: [
                        {
                            Cd: message.block4.MT23B.Typ.content
                        }
                    ],
                    CtgyPurp: {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 4)[0]
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt),
                XchgRate: check convertToDecimal(message.block4.MT36?.Rt),
                InstdAmt: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                        ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(instrdAmnt = message.block4.MT33B, stlmntAmnt = message.block4.MT32A),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                DbtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT52A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn)
                    }
                },
                ChrgBr: check getDetailsChargesCd(message.block4.MT71A.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
                DbtrAcct: {
                    Id: {
                        IBAN: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[0], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[1]),
                        Othr: {
                            Id: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[1], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[2]),
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT50A?.Acc, message.block4.MT50K?.Acc, prtyIdn1 = message.block4.MT50F?.PrtyIdn)
                            }
                        }
                    }
                },
                Dbtr: {
                    Id: {
                        OrgId: {
                            AnyBIC: message.block4.MT50A?.IdnCd?.content
                        },
                        PrvtId: {
                            Othr: [
                                {
                                    Id: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[0],
                                    SchmeNm: {
                                        Cd: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[3]
                                    },
                                    Issr: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[4]
                                }
                            ]
                        }
                    },
                    Nm: getName(message.block4.MT50F?.Nm, message.block4.MT50K?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(message.block4.MT50F?.AdrsLine, message.block4.MT50K?.AdrsLine),
                        Ctry: getCountryAndTown(message.block4.MT50F?.CntyNTw)[0],
                        TwnNm: getCountryAndTown(message.block4.MT50F?.CntyNTw)[1]
                    }
                },
                PrvsInstgAgt1: {
                    FinInstnId: {
                        BICFI: getMT1XXSenderToReceiverInformation(message.block4.MT72)[4],
                        Nm: getMT1XXSenderToReceiverInformation(message.block4.MT72)[5]
                    }
                },
                IntrmyAgt1: {
                    FinInstnId: {
                        BICFI: message.block4.MT56A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn)
                    }
                },
                ChrgsInf: check getChargesInformation(message.block4.MT71F, message.block4.MT71G),
                RgltryRptg: getRegulatoryReporting(message.block4.MT77B?.Nrtv?.content),
                RmtInf: {Ustrd: [getRemmitanceInformation(message.block4.MT70?.Nrtv?.content)], Strd: []},
                InstrForNxtAgt: [
                    {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 1)[0],
                        InstrInf: getMT103InstructionCode(message.block4.MT23E, 1)[1]
                    },
                    {
                        Cd: getMT1XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT1XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                InstrForCdtrAgt: [
                    {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 2)[0],
                        InstrInf: getMT103InstructionCode(message.block4.MT23E, 2)[1]
                    },
                    {
                        Cd: getMT1XXSenderToReceiverInformation(message.block4.MT72)[2],
                        InstrInf: getMT1XXSenderToReceiverInformation(message.block4.MT72)[3]
                    }
                ],
                Purp: {
                    Cd: getMandatoryFields(message.block4.MT26T?.Typ?.content)
                }
            }
        ]
    }
};

# Transforms the given SWIFT MT103 message to its corresponding ISO 20022 Pacs.008 format.
#
# This function extracts various fields from the SWIFT MT103 message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT103 message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs008Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT103(swiftmt:MT103Message message) returns pacsIsoRecord:Pacs008Document|error => {
    FIToFICstmrCdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT54D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT54D?.AdrsLine)
                        }
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn, prtyIdn2 = message.block4.MT54B?.PrtyIdn, prtyIdn3 = message.block4.MT54D?.PrtyIdn)
                            }
                        }
                    }
                },
                ThrdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT55A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT55A?.PrtyIdn, message.block4.MT55B?.PrtyIdn, message.block4.MT55D?.PrtyIdn),
                        Nm: getName(message.block4.MT55D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT55D?.AdrsLine)
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                    Ccy: message.block4.MT32A.Ccy.content
                }
            },
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: [
            {
                Cdtr: {
                    Id: {
                        OrgId: {
                            AnyBIC: message.block4.MT59A?.IdnCd?.content
                        }
                    },
                    Nm: getName(message.block4.MT59F?.Nm, message.block4.MT59?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(message.block4.MT59F?.AdrsLine, message.block4.MT59?.AdrsLine),
                        Ctry: getCountryAndTown(message.block4.MT59F?.CntyNTw)[0],
                        TwnNm: getCountryAndTown(message.block4.MT59F?.CntyNTw)[1]
                    }
                },
                CdtrAcct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT59F?.Acc, acc2 = message.block4.MT59?.Acc, acc3 = message.block4.MT59A?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT59F?.Acc, acc2 = message.block4.MT59?.Acc, acc3 = message.block4.MT59A?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT59F?.Acc, message.block4.MT59?.Acc, message.block4.MT59A?.Acc)
                            }
                        }
                    }
                },
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn, message.block4.MT57B?.PrtyIdn, message.block4.MT57C?.PrtyIdn, message.block4.MT57D?.PrtyIdn),
                        Nm: getName(message.block4.MT57D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT57D?.AdrsLine)
                        }
                    }
                },
                IntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                PmtId: {
                    EndToEndId: getEndToEndId(remmitanceInfo = message.block4.MT70?.Nrtv?.content),
                    InstrId: message.block4.MT20.msgId.content,
                    UETR: message.block3?.NdToNdTxRef?.value
                },
                SttlmTmReq: {
                    CLSTm: getTimeIndication(message.block4.MT13C)[0]
                },
                SttlmTmIndctn: {
                    CdtDtTm: getTimeIndication(message.block4.MT13C)[1],
                    DbtDtTm: getTimeIndication(message.block4.MT13C)[2]
                },
                PmtTpInf: {
                    SvcLvl: [
                        {
                            Cd: message.block4.MT23B.Typ.content
                        }
                    ],
                    CtgyPurp: {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 4)[0]
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt),
                XchgRate: check convertToDecimal(message.block4.MT36?.Rt),
                InstdAmt: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                        ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(instrdAmnt = message.block4.MT33B, stlmntAmnt = message.block4.MT32A),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                DbtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT52A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                        Nm: getName(message.block4.MT52D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                        }
                    }
                },
                ChrgBr: check getDetailsChargesCd(message.block4.MT71A.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
                DbtrAcct: {
                    Id: {
                        IBAN: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[0], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[1]),
                        Othr: {
                            Id: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[1], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[2]),
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT50A?.Acc, message.block4.MT50K?.Acc, prtyIdn1 = message.block4.MT50F?.PrtyIdn)
                            }
                        }
                    }
                },
                Dbtr: {
                    Id: {
                        OrgId: {
                            AnyBIC: message.block4.MT50A?.IdnCd?.content
                        },
                        PrvtId: {
                            Othr: [
                                {
                                    Id: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[0],
                                    SchmeNm: {
                                        Cd: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[3]
                                    },
                                    Issr: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[4]
                                }
                            ]
                        }
                    },
                    Nm: getName(message.block4.MT50F?.Nm, message.block4.MT50K?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(message.block4.MT50F?.AdrsLine, message.block4.MT50K?.AdrsLine),
                        Ctry: getCountryAndTown(message.block4.MT50F?.CntyNTw)[0],
                        TwnNm: getCountryAndTown(message.block4.MT50F?.CntyNTw)[1]
                    }
                },
                PrvsInstgAgt1: {
                    FinInstnId: {
                        BICFI: getMT1XXSenderToReceiverInformation(message.block4.MT72)[4],
                        Nm: getMT1XXSenderToReceiverInformation(message.block4.MT72)[5]
                    }
                },
                IntrmyAgt1: {
                    FinInstnId: {
                        BICFI: message.block4.MT56A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56C?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                        Nm: getName(message.block4.MT56D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                        }
                    }
                },
                ChrgsInf: check getChargesInformation(message.block4.MT71F, message.block4.MT71G),
                RgltryRptg: getRegulatoryReporting(message.block4.MT77B?.Nrtv?.content),
                RmtInf: {Ustrd: [getRemmitanceInformation(message.block4.MT70?.Nrtv?.content)], Strd: []},
                InstrForNxtAgt: [
                    {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 1)[0],
                        InstrInf: getMT103InstructionCode(message.block4.MT23E, 1)[1]
                    },
                    {
                        Cd: getMT1XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT1XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                InstrForCdtrAgt: [
                    {
                        Cd: getMT103InstructionCode(message.block4.MT23E, 2)[0],
                        InstrInf: getMT103InstructionCode(message.block4.MT23E, 2)[1]
                    },
                    {
                        Cd: getMT1XXSenderToReceiverInformation(message.block4.MT72)[2],
                        InstrInf: getMT1XXSenderToReceiverInformation(message.block4.MT72)[3]
                    }
                ],
                Purp: {
                    Cd: getMandatoryFields(message.block4.MT26T?.Typ?.content)
                }
            }
        ]
    }
};

# Transforms the given SWIFT MT104 message to its corresponding ISO 20022 Pacs.003 format.
#
# This function extracts various fields from the SWIFT MT104 message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT104 message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs003Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT104DrctDbt(swiftmt:MT104Message message) returns pacsIsoRecord:Pacs003Document|error => {
    FIToFICstmrDrctDbt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B)
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32B.Amnt),
                    Ccy: message.block4.MT32B.Ccy.content
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        DrctDbtTxInf: check getDirectDebitTransactionInfoMT104(message.block4, message.block3)
    }
};

# Processes an MT104 direct debit message and extracts direct debit transaction information into ISO 20022 format.
# The function iterates over each transaction within the message, extracts relevant fields, and maps them 
# to the `DirectDebitTransactionInformation31` ISO record structure. It handles various transaction fields 
# such as party identifiers, account information, settlement details, and remittance information.
#
# + block4 - The parsed block4 of MT104 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT104 SWIFT message containing end to end id.
# + return - Returns an array of `DirectDebitTransactionInformation31` records, each corresponding to a transaction 
# in the input message. If any error occurs during field extraction or conversion, an error will be returned.
isolated function getDirectDebitTransactionInfoMT104(swiftmt:MT104Block4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:DirectDebitTransactionInformation31[]|error {
    pacsIsoRecord:DirectDebitTransactionInformation31[] drctDbtTxInfArray = [];
    foreach swiftmt:MT104Transaction transaxion in block4.Transaction {
        swiftmt:MT23E? instrCd = <swiftmt:MT23E?>getMT104RepeatingFields(block4, transaxion.MT23E, "23E");
        swiftmt:MT50A? creditor50A = <swiftmt:MT50A?>getMT104RepeatingFields(block4, transaxion.MT50A, "50A");
        swiftmt:MT50C? instgPrty50C = <swiftmt:MT50C?>getMT104RepeatingFields(block4, transaxion.MT50C, "50C");
        swiftmt:MT50K? creditor50K = <swiftmt:MT50K?>getMT104RepeatingFields(block4, transaxion.MT50K, "50K");
        swiftmt:MT50L? instgPrty50L = <swiftmt:MT50L?>getMT104RepeatingFields(block4, transaxion.MT50L, "50L");
        swiftmt:MT52A? accWthInstn52A = <swiftmt:MT52A?>getMT104RepeatingFields(block4, transaxion.MT52A, "52A");
        swiftmt:MT52C? accWthInstn52C = <swiftmt:MT52C?>getMT104RepeatingFields(block4, transaxion.MT52C, "52C");
        swiftmt:MT52D? accWthInstn52D = <swiftmt:MT52D?>getMT104RepeatingFields(block4, transaxion.MT52D, "52D");
        swiftmt:MT71A? dtlsOfChrgs = <swiftmt:MT71A?>getMT104RepeatingFields(block4, transaxion.MT71A, "71A");
        swiftmt:MT77B? rgltryRptg = <swiftmt:MT77B?>getMT104RepeatingFields(block4, transaxion.MT77B, "77B");

        drctDbtTxInfArray.push({
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: creditor50A?.IdnCd?.content
                    }
                },
                Nm: getName(creditor50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(creditor50K?.AdrsLine)
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(creditor50A?.Acc, acc2 = creditor50K?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(creditor50A?.Acc, acc2 = creditor50K?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(creditor50A?.Acc, creditor50K?.Acc)
                        }
                    }
                }
            },
            CdtrAgt: {
                FinInstnId: {
                    BICFI: accWthInstn52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(accWthInstn52A?.PrtyIdn, accWthInstn52C?.PrtyIdn, accWthInstn52D?.PrtyIdn),
                    Nm: getName(accWthInstn52D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(accWthInstn52D?.AdrsLine)
                    }
                }
            },
            DbtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(transaxion.MT59A?.Acc, transaxion.MT59?.Acc)
                        }
                    }
                }
            },
            IntrBkSttlmDt: convertToISOStandardDate(block4.MT30.Dt),
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            InstdAmt: {
                ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(transaxion.MT32B, transaxion.MT33B),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            XchgRate: check convertToDecimal(transaxion.MT36?.Rt),
            DrctDbtTx: {
                MndtRltdInf: {
                    MndtId: transaxion.MT21C?.Ref?.content
                }
            },
            PmtId: {
                EndToEndId: getEndToEndId(block4.MT21R?.Ref?.content, transaxion.MT70?.Nrtv?.content, transaxion.MT21.Ref.content),
                InstrId: block4.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value,
                TxId: transaxion.MT21.Ref.content
            },
            PmtTpInf: {
                CtgyPurp: {
                    Cd: instrCd?.InstrnCd?.content
                }
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: transaxion.MT57A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn, transaxion.MT57C?.PrtyIdn, transaxion.MT57D?.PrtyIdn),
                    Nm: getName(transaxion.MT57D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(transaxion.MT57D?.AdrsLine)
                    }
                }
            },
            IntrmyAgt1: {
                FinInstnId: {
                    BICFI: block4.MT53A?.IdnCd?.content,
                    LEI: getPartyIdentifierOrAccount2(block4.MT53A?.PrtyIdn, prtyIdn2 = block4.MT53B?.PrtyIdn)[0]
                }
            },
            InitgPty: {
                Id: {
                    OrgId: {
                        AnyBIC: instgPrty50C?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifier(instgPrty50L?.PrtyIdn)
                            }
                        ]
                    }
                }
            },
            ChrgBr: check getDetailsChargesCd(dtlsOfChrgs?.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: transaxion.MT59A?.IdnCd?.content
                    }
                },
                Nm: getName(transaxion.MT59?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(transaxion.MT59?.AdrsLine)
                }
            },
            RgltryRptg: getRegulatoryReporting(rgltryRptg?.Nrtv?.content),
            RmtInf: {
                Ustrd: [getRemmitanceInformation(transaxion.MT70?.Nrtv?.content)],
                Strd: []
            }
        }
        );
    }
    return drctDbtTxInfArray;
}

# Transforms the given SWIFT MT104 message to its corresponding ISO 20022 Pain.008 format.
#
# This function extracts various fields from the SWIFT MT104 message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT104 message as a record value.
# + return - Returns the transformed ISO 20022 `Pain008Document` structure.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT104ReqDbtTrf(swiftmt:MT104Message message) returns painIsoRecord:Pain008Document|error => {
    CstmrDrctDbtInitn: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            InitgPty: {
                Id: {
                    OrgId: {
                        AnyBIC: message.block4.MT50C?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifier(message.block4.MT50L?.PrtyIdn)
                            }
                        ]
                    }
                }
            },
            FwdgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        PmtInf: check getPaymentInformationOfMT104(message.block4, message.block3)
    }
};

# Processes an MT104 message and extracts payment information into ISO 20022 format.
# This function maps the SWIFT MT104 transaction details into an array of `PaymentInstruction45` ISO records.
# It extracts important fields such as creditor information, settlement details, and payment method from each transaction.
#
# + block4 - The parsed block4 of MT104 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT104 SWIFT message containing end to end id.
# + return - Returns an array of `PaymentInstruction45` records, each corresponding to a transaction 
# in the input message. An error is returned if any field extraction or conversion fails.
isolated function getPaymentInformationOfMT104(swiftmt:MT104Block4 block4, swiftmt:Block3? block3) returns painIsoRecord:PaymentInstruction45[]|error {
    painIsoRecord:PaymentInstruction45[] paymentInstructionArray = [];
    foreach swiftmt:MT104Transaction transaxion in block4.Transaction {
        swiftmt:MT26T? trnsTp = <swiftmt:MT26T?>getMT104RepeatingFields(block4, transaxion.MT26T, "26T");
        swiftmt:MT50A? creditor50A = <swiftmt:MT50A?>getMT104RepeatingFields(block4, transaxion.MT50A, "50A");
        swiftmt:MT50K? creditor50K = <swiftmt:MT50K?>getMT104RepeatingFields(block4, transaxion.MT50K, "50K");
        swiftmt:MT52A? accWthInstn52A = <swiftmt:MT52A?>getMT104RepeatingFields(block4, transaxion.MT52A, "52A");
        swiftmt:MT52C? accWthInstn52C = <swiftmt:MT52C?>getMT104RepeatingFields(block4, transaxion.MT52C, "52C");
        swiftmt:MT52D? accWthInstn52D = <swiftmt:MT52D?>getMT104RepeatingFields(block4, transaxion.MT52D, "52D");
        swiftmt:MT71A? dtlsOfChrgs = <swiftmt:MT71A?>getMT104RepeatingFields(block4, transaxion.MT71A, "71A");
        swiftmt:MT77B? rgltryRptg = <swiftmt:MT77B?>getMT104RepeatingFields(block4, transaxion.MT77B, "77B");

        paymentInstructionArray.push({
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: creditor50A?.IdnCd?.content
                    }
                },
                Nm: getName(creditor50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(creditor50K?.AdrsLine)
                }
            },
            ReqdColltnDt: convertToISOStandardDateMandatory(block4.MT30.Dt),
            CdtrAgt: {
                FinInstnId: {
                    BICFI: accWthInstn52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(accWthInstn52A?.PrtyIdn, accWthInstn52C?.PrtyIdn, accWthInstn52D?.PrtyIdn),
                    Nm: getName(accWthInstn52D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(accWthInstn52D?.AdrsLine)
                    }
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(creditor50A?.Acc, acc2 = creditor50K?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(creditor50A?.Acc, acc2 = creditor50K?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(creditor50A?.Acc, creditor50K?.Acc)
                        }
                    }
                }
            },
            PmtInfId: transaxion.MT21.Ref.content,
            PmtTpInf: {
                CtgyPurp: {
                    Cd: block4.MT23E?.InstrnCd?.content
                }
            },
            ChrgBr: check getDetailsChargesCd(dtlsOfChrgs?.Cd).ensureType(painIsoRecord:ChargeBearerType1Code),
            DrctDbtTxInf: [
                {
                    DrctDbtTx: {
                        MndtRltdInf: {
                            MndtId: transaxion.MT21C?.Ref?.content
                        }
                    },
                    DbtrAcct: {
                        Id: {
                            IBAN: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc)[0],
                            Othr: {
                                Id: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc)[1],
                                SchmeNm: {
                                    Cd: getSchemaCode(transaxion.MT59A?.Acc, transaxion.MT59?.Acc)
                                }
                            }
                        }
                    },
                    PmtId: {
                        EndToEndId: getEndToEndId(block4.MT21R?.Ref?.content, transaxion.MT70?.Nrtv?.content, transaxion.MT21.Ref.content),
                        InstrId: block4.MT20.msgId.content,
                        UETR: block3?.NdToNdTxRef?.value
                    },
                    DbtrAgt: {
                        FinInstnId: {
                            BICFI: transaxion.MT57A?.IdnCd?.content,
                            LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn, transaxion.MT57C?.PrtyIdn, transaxion.MT57D?.PrtyIdn),
                            Nm: getName(transaxion.MT57D?.Nm),
                            PstlAdr: {
                                AdrLine: getAddressLine(transaxion.MT57D?.AdrsLine)
                            }
                        }
                    },
                    InstdAmt: {
                        ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                            ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(transaxion.MT32B, transaxion.MT33B),
                            Ccy: transaxion.MT32B.Ccy.content
                        }
                    },
                    Dbtr: {
                        Id: {
                            OrgId: {
                                AnyBIC: transaxion.MT59A?.IdnCd?.content
                            }
                        },
                        Nm: getName(transaxion.MT59?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(transaxion.MT59?.AdrsLine)
                        }
                    },
                    RgltryRptg: getRegulatoryReporting(rgltryRptg?.Nrtv?.content),
                    RmtInf: {Ustrd: [getRemmitanceInformation(transaxion.MT70?.Nrtv?.content)], Strd: []},
                    Purp: {
                        Cd: getMandatoryFields(trnsTp?.Typ?.content)
                    }
                }
            ],
            PmtMtd: "DD"
        });
    }
    return paymentInstructionArray;
}

# Transforms the given SWIFT MT107 message to its corresponding ISO 20022 Pacs.003 format.
#
# This function extracts various fields from the SWIFT MT107 message and maps them to 
# the appropriate ISO 20022 structure.
#
# + message - The parsed MT107 message as a record value.
# + return - Returns the transformed ISO 20022 `Pacs003Document` structure if the message instruction is not `RTND`.
# An error is returned if there is any failure in transforming the SWIFT message to ISO 20022 format.
isolated function transformMT107(swiftmt:MT107Message message) returns pacsIsoRecord:Pacs003Document|error => {
    FIToFICstmrDrctDbt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B)
            },
            TtlIntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32B.Amnt),
                    Ccy: message.block4.MT32B.Ccy.content
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: message.block4.MT51A?.IdnCd?.content,
                    LEI: message.block4.MT51A?.PrtyIdn?.content
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        DrctDbtTxInf: check getDirectDebitTransactionInfoMT107(message.block4, message.block3)
    }
};

# Processes an MT107 direct debit message and extracts direct debit transaction information into ISO 20022 format.
#
# The function iterates over each transaction within the message, extracts relevant fields, and maps them 
# to the `DirectDebitTransactionInformation31` ISO record structure. It handles various transaction fields 
# such as party identifiers, account information, settlement details, and remittance information.
#
# + block4 - The parsed block4 of MT107 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT107 SWIFT message containing end to end id.
# + return - Returns an array of `DirectDebitTransactionInformation31` records, each corresponding to a transaction 
# in the input message. If any error occurs during field extraction or conversion, an error will be returned.
isolated function getDirectDebitTransactionInfoMT107(swiftmt:MT107Block4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:DirectDebitTransactionInformation31[]|error {
    pacsIsoRecord:DirectDebitTransactionInformation31[] drctDbtTxInfArray = [];
    foreach swiftmt:MT107Transaction transaxion in block4.Transaction {
        swiftmt:MT23E? instrCd = <swiftmt:MT23E?>getMT107RepeatingFields(block4, transaxion.MT23E, "23E");
        swiftmt:MT50A? creditor50A = <swiftmt:MT50A?>getMT107RepeatingFields(block4, transaxion.MT50A, "50A");
        swiftmt:MT50C? instgPrty50C = <swiftmt:MT50C?>getMT107RepeatingFields(block4, transaxion.MT50C, "50C");
        swiftmt:MT50K? creditor50K = <swiftmt:MT50K?>getMT107RepeatingFields(block4, transaxion.MT50K, "50K");
        swiftmt:MT50L? instgPrty50L = <swiftmt:MT50L?>getMT107RepeatingFields(block4, transaxion.MT50L, "50L");
        swiftmt:MT52A? accWthInstn52A = <swiftmt:MT52A?>getMT107RepeatingFields(block4, transaxion.MT52A, "52A");
        swiftmt:MT52C? accWthInstn52C = <swiftmt:MT52C?>getMT107RepeatingFields(block4, transaxion.MT52C, "52C");
        swiftmt:MT52D? accWthInstn52D = <swiftmt:MT52D?>getMT107RepeatingFields(block4, transaxion.MT52D, "52D");
        swiftmt:MT71A? dtlsOfChrgs = <swiftmt:MT71A?>getMT107RepeatingFields(block4, transaxion.MT71A, "71A");
        swiftmt:MT77B? rgltryRptg = <swiftmt:MT77B?>getMT107RepeatingFields(block4, transaxion.MT77B, "77B");

        drctDbtTxInfArray.push({
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: creditor50A?.IdnCd?.content
                    }
                },
                Nm: getName(creditor50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(creditor50K?.AdrsLine)
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(creditor50A?.Acc, acc2 = creditor50K?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(creditor50A?.Acc, acc2 = creditor50K?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(creditor50A?.Acc, creditor50K?.Acc)
                        }
                    }
                }
            },
            CdtrAgt: {
                FinInstnId: {
                    BICFI: accWthInstn52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(accWthInstn52A?.PrtyIdn, accWthInstn52C?.PrtyIdn, accWthInstn52D?.PrtyIdn),
                    Nm: getName(accWthInstn52D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(accWthInstn52D?.AdrsLine)
                    }
                }
            },
            DbtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(transaxion.MT59A?.Acc, acc2 = transaxion.MT59?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(transaxion.MT59A?.Acc, transaxion.MT59?.Acc)
                        }
                    }
                }
            },
            IntrBkSttlmDt: convertToISOStandardDate(block4.MT30.Dt),
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            InstdAmt: {
                ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(instrdAmnt = transaxion.MT33B),
                    Ccy: getMandatoryFields(transaxion.MT33B?.Ccy?.content)
                }
            },
            XchgRate: check convertToDecimal(transaxion.MT36?.Rt),
            DrctDbtTx: {
                MndtRltdInf: {
                    MndtId: transaxion.MT21C?.Ref?.content
                }
            },
            PmtId: {
                EndToEndId: getEndToEndId(remmitanceInfo = transaxion.MT70?.Nrtv?.content, transactionId = transaxion.MT21.Ref.content),
                InstrId: block4.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value,
                TxId: transaxion.MT21.Ref.content
            },
            PmtTpInf: {
                CtgyPurp: {
                    Cd: instrCd?.InstrnCd?.content
                }
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: transaxion.MT57A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn, transaxion.MT57C?.PrtyIdn, transaxion.MT57D?.PrtyIdn),
                    Nm: getName(transaxion.MT57D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(transaxion.MT57D?.AdrsLine)
                    }
                }
            },
            IntrmyAgt1: {
                FinInstnId: {
                    BICFI: block4.MT53A?.IdnCd?.content,
                    LEI: getPartyIdentifierOrAccount2(block4.MT53A?.PrtyIdn, block4.MT53B?.PrtyIdn)[0]
                }
            },
            InitgPty: {
                Id: {
                    OrgId: {
                        AnyBIC: instgPrty50C?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifier(instgPrty50L?.PrtyIdn)
                            }
                        ]
                    }
                }
            },
            ChrgBr: check getDetailsChargesCd(dtlsOfChrgs?.Cd).ensureType(pacsIsoRecord:ChargeBearerType1Code),
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: transaxion.MT59A?.IdnCd?.content
                    }
                },
                Nm: getName(transaxion.MT59?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(transaxion.MT59?.AdrsLine)
                }
            },
            RgltryRptg: getRegulatoryReporting(rgltryRptg?.Nrtv?.content),
            RmtInf: {
                Ustrd: [getRemmitanceInformation(transaxion.MT70?.Nrtv?.content)],
                Strd: []
            }
        }
        );
    }
    return drctDbtTxInfArray;
}

# This function transforms an MT200 SWIFT message into an ISO 20022 PACS.009 document.
# The relevant fields from the MT200 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT200 message as a record value.
# + return - Returns a `Pacs009Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT200ToPacs009(swiftmt:MT200Message message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(mt53B = message.block4.MT53B),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53B?.PrtyIdn)[0]
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53B?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53B?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53B?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: [
            {
                Cdtr: {FinInstnId: {}},
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn, message.block4.MT57B?.PrtyIdn, message.block4.MT57D?.PrtyIdn),
                        Nm: getName(message.block4.MT57D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT57D?.AdrsLine)
                        }
                    }
                },
                IntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt),
                PmtId: {
                    EndToEndId: "",
                    InstrId: message.block4.MT20.msgId.content,
                    UETR: message.block3?.NdToNdTxRef?.value
                },
                Dbtr: {FinInstnId: {}},
                IntrmyAgt1: {
                    FinInstnId: {
                        BICFI: message.block4.MT56A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                        Nm: getName(message.block4.MT56D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                        }
                    }
                },
                InstrForNxtAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                InstrForCdtrAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[2],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[3]
                    }
                ]
            }
        ]
    }
};

# This function transforms an MT200 SWIFT message into an ISO 20022 CAMT.050 document.
# The relevant fields from the MT200 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT200 message as a record value.
# + return - Returns a `Camt050Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT200ToCamt050(swiftmt:MT200Message message) returns camtIsoRecord:Camt050Document|error => {
    LqdtyCdtTrf: {
        MsgHdr: {
            MsgId: uuid:createType4AsString().substring(0, 35),
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string)
        },
        LqdtyCdtTrf: {
            LqdtyTrfId: {
                EndToEndId: "",
                InstrId: message.block4.MT20.msgId.content,
                UETR: message.block3?.NdToNdTxRef?.value
            },
            TrfdAmt: {
                AmtWthCcy: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                }
            },
            SttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt)
        }
    }
};

# This function transforms an MT201 SWIFT message into an ISO 20022 PACS.009 document.
# The relevant fields from the MT201 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT201 message as a record value.
# + return - Returns a `Pacs009Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT201(swiftmt:MT201Message message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            CtrlSum: check convertToDecimal(message.block4.MT19.Amnt),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(mt53B = message.block4.MT53B),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53B?.PrtyIdn)[0]
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53B?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53B?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53B?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: check getCreditTransferTransactionInfo(message.block4, message.block3)
    }
};

# This function extracts credit transfer transaction information from an MT201 SWIFT message
# and maps it to an array of ISO 20022 CreditTransferTransaction62 records.
#
# + block4 - The parsed block4 of MT201 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT201 SWIFT message containing end to end id.
# + return - Returns an array of `CreditTransferTransaction62` objects if the extraction is successful,
# otherwise returns an error.
isolated function getCreditTransferTransactionInfo(swiftmt:MT201Block4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:CreditTransferTransaction62[]|error {
    pacsIsoRecord:CreditTransferTransaction62[] cdtTrfTxInfArray = [];
    foreach swiftmt:MT201Transaction transaxion in block4.Transaction {
        swiftmt:MT72? sndToRcvrInfo = getMT201RepeatingFields(block4, transaxion.MT72, "72");
        cdtTrfTxInfArray.push({
            Cdtr: {FinInstnId: {}},
            CdtrAgt: {
                FinInstnId: {
                    BICFI: transaxion.MT57A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT57A?.PrtyIdn, transaxion.MT57B?.PrtyIdn, transaxion.MT57D?.PrtyIdn),
                    Nm: getName(transaxion.MT57D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(transaxion.MT57D?.AdrsLine)
                    }
                }
            },
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            IntrBkSttlmDt: convertToISOStandardDate(block4.MT30.Dt),
            PmtId: {
                EndToEndId: "",
                InstrId: transaxion.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value
            },
            Dbtr: {FinInstnId: {}},
            IntrmyAgt1: {
                FinInstnId: {
                    BICFI: transaxion.MT56A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT56A?.PrtyIdn, transaxion.MT56D?.PrtyIdn),
                    Nm: getName(transaxion.MT56D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(transaxion.MT56D?.AdrsLine)
                    }
                }
            },
            InstrForNxtAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[0],
                    InstrInf: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[1]
                }
            ],
            InstrForCdtrAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[2],
                    InstrInf: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[3]
                }
            ]
        });
    }
    return cdtTrfTxInfArray;
}

# This function transforms an MT202 SWIFT message into an ISO 20022 Pacs009Document format.
#
# + message - The parsed MT202 message as a record value.
# + return - Returns a `Pacs009Document` object if the transformation is successful,
# otherwise returns an error.
isolated function transformMT202(swiftmt:MT202Message message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT54D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT54D?.AdrsLine)
                        }
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn, prtyIdn2 = message.block4.MT54B?.PrtyIdn, prtyIdn3 = message.block4.MT54D?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: [
            {
                Cdtr: {
                    FinInstnId: {
                        BICFI: message.block4.MT58A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT58A?.PrtyIdn, message.block4.MT58D?.PrtyIdn),
                        Nm: getName(message.block4.MT58D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT58D?.AdrsLine)
                        }
                    }
                },
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn, message.block4.MT57B?.PrtyIdn, message.block4.MT57D?.PrtyIdn),
                        Nm: getName(message.block4.MT57D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT57D?.AdrsLine)
                        }
                    }
                },
                IntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt),
                PmtId: {
                    EndToEndId: message.block4.MT21.Ref.content,
                    InstrId: message.block4.MT20.msgId.content,
                    UETR: message.block3?.NdToNdTxRef?.value
                },
                SttlmTmReq: {
                    CLSTm: getTimeIndication(message.block4.MT13C)[0]
                },
                SttlmTmIndctn: {
                    CdtDtTm: getTimeIndication(message.block4.MT13C)[1],
                    DbtDtTm: getTimeIndication(message.block4.MT13C)[2]
                },
                Dbtr: {
                    FinInstnId: {
                        BICFI: message.block4.MT52A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                        Nm: getName(message.block4.MT52D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                        }
                    }
                },
                IntrmyAgt1: {
                    FinInstnId: {
                        BICFI: message.block4.MT56A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                        Nm: getName(message.block4.MT56D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                        }
                    }
                },
                InstrForNxtAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                InstrForCdtrAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[2],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[3]
                    }
                ]
            }
        ]
    }
};

# This function transforms an MT202COV SWIFT message into an ISO 20022 Pacs009Document format.
#
# + message - The parsed MT202COV message as a record value.
# + return - Returns a `Pacs009Document` object if the transformation is successful,
# otherwise returns an error.
isolated function transformMT202COV(swiftmt:MT202COVMessage message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT54D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT54D?.AdrsLine)
                        }
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn, prtyIdn2 = message.block4.MT54B?.PrtyIdn, prtyIdn3 = message.block4.MT54D?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: check getMT202COVCreditTransfer(message.block4, message.block3)
    }
};

# This function extracts and transforms credit transfer transaction information 
# from an MT202COV SWIFT message into an array of ISO 20022 CreditTransferTransaction62 records.
#
# + block4 - The parsed block4 of MT202 COV SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT202 COV SWIFT message containing end to end id.
# + return - Returns an array of `CreditTransferTransaction62` objects if the transformation is successful,
# otherwise returns an error.
isolated function getMT202COVCreditTransfer(swiftmt:MT202COVBlock4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:CreditTransferTransaction62[]|error {
    pacsIsoRecord:CreditTransferTransaction62[] cdtTrfTxInfArray = [];
    cdtTrfTxInfArray.push({
        Cdtr: {FinInstnId: {}},
        CdtrAgt: {
            FinInstnId: {
                BICFI: block4.MT58A?.IdnCd?.content,
                LEI: getPartyIdentifier(block4.MT58A?.PrtyIdn, block4.MT58D?.PrtyIdn),
                Nm: getName(block4.MT58D?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.MT58D?.AdrsLine)
                }
            }
        },
        IntrBkSttlmAmt: {
            ActiveCurrencyAndAmount_SimpleType: {
                ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(block4.MT32A.Amnt),
                Ccy: block4.MT32A.Ccy.content
            }
        },
        IntrBkSttlmDt: convertToISOStandardDate(block4.MT32A.Dt),
        PmtId: {
            EndToEndId: block4.MT21.Ref.content,
            InstrId: block4.MT20.msgId.content,
            UETR: block3?.NdToNdTxRef?.value,
            TxId: block4.MT21.Ref.content
        },
        SttlmTmReq: {
            CLSTm: getTimeIndication(block4.MT13C)[0]
        },
        SttlmTmIndctn: {
            CdtDtTm: getTimeIndication(block4.MT13C)[1],
            DbtDtTm: getTimeIndication(block4.MT13C)[2]
        },
        Dbtr: {FinInstnId: {}},
        DbtrAgt: {
            FinInstnId: {
                BICFI: block4.MT52A?.IdnCd?.content,
                LEI: getPartyIdentifier(block4.MT52A?.PrtyIdn, block4.MT52D?.PrtyIdn),
                Nm: getName(block4.MT52D?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.MT52D?.AdrsLine)
                }
            }
        },
        IntrmyAgt1: getIntermediaryAgent1(block4.MT56A, block4.MT56D, block4.MT57A, block4.MT57B, block4.MT57D),
        IntrmyAgt2: getIntermediaryAgent2(block4.MT56A, block4.MT56D, block4.MT57A, block4.MT57B, block4.MT57D),
        InstrForNxtAgt: [
            {
                Cd: getMT2XXSenderToReceiverInformation(block4.MT72)[0],
                InstrInf: getMT2XXSenderToReceiverInformation(block4.MT72)[1]
            }
        ],
        InstrForCdtrAgt: [
            {
                Cd: getMT2XXSenderToReceiverInformation(block4.MT72)[2],
                InstrInf: getMT2XXSenderToReceiverInformation(block4.MT72)[3]
            }
        ],
        UndrlygCstmrCdtTrf: {
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: block4.UndrlygCstmrCdtTrf.MT50A?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[0],
                                SchmeNm: {
                                    Cd: getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[3]
                                },
                                Issr: getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[4]
                            }
                        ]
                    }
                },
                Nm: getName(block4.UndrlygCstmrCdtTrf.MT50F?.Nm, block4.UndrlygCstmrCdtTrf.MT50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.UndrlygCstmrCdtTrf.MT50F?.AdrsLine, block4.UndrlygCstmrCdtTrf.MT50K?.AdrsLine),
                    Ctry: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT50F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT50F?.CntyNTw)[1]
                }
            },
            DbtrAcct: {
                Id: {
                    IBAN: getAccountId(validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT50A?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT50K?.Acc)[0], getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[1]),
                    Othr: {
                        Id: getAccountId(validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT50A?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT50K?.Acc)[1], getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[2]),
                        SchmeNm: {
                            Cd: getSchemaCode(block4.UndrlygCstmrCdtTrf.MT50A?.Acc, block4.UndrlygCstmrCdtTrf.MT50K?.Acc, prtyIdn1 = block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)
                        }
                    }
                }
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: block4.UndrlygCstmrCdtTrf.MT52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(block4.UndrlygCstmrCdtTrf.MT52A?.PrtyIdn, block4.UndrlygCstmrCdtTrf.MT52D?.PrtyIdn),
                    Nm: getName(block4.UndrlygCstmrCdtTrf.MT52D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(block4.UndrlygCstmrCdtTrf.MT52D?.AdrsLine)
                    }
                }
            },
            InstdAmt: {
                ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(instrdAmnt = block4.UndrlygCstmrCdtTrf.MT33B),
                    Ccy: getMandatoryFields(block4.UndrlygCstmrCdtTrf.MT33B?.Ccy?.content)
                }
            },
            IntrmyAgt1: getIntermediaryAgent1(block4.UndrlygCstmrCdtTrf.MT56A, block4.UndrlygCstmrCdtTrf.MT56D, block4.UndrlygCstmrCdtTrf.MT57A, block4.UndrlygCstmrCdtTrf.MT57B, block4.UndrlygCstmrCdtTrf.MT57D),
            IntrmyAgt2: getIntermediaryAgent2(block4.UndrlygCstmrCdtTrf.MT56A, block4.UndrlygCstmrCdtTrf.MT56D, block4.UndrlygCstmrCdtTrf.MT57A, block4.UndrlygCstmrCdtTrf.MT57B, block4.UndrlygCstmrCdtTrf.MT57D),
            CdtrAgt: {FinInstnId: {}},
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: block4.UndrlygCstmrCdtTrf.MT59A?.IdnCd?.content
                    }
                },
                Nm: getName(block4.UndrlygCstmrCdtTrf.MT59F?.Nm, block4.UndrlygCstmrCdtTrf.MT59?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.UndrlygCstmrCdtTrf.MT59F?.AdrsLine, block4.UndrlygCstmrCdtTrf.MT59?.AdrsLine),
                    Ctry: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT59F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT59F?.CntyNTw)[1]
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT59F?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT59?.Acc, acc3 = block4.UndrlygCstmrCdtTrf.MT59A?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT59F?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT59?.Acc, acc3 = block4.UndrlygCstmrCdtTrf.MT59A?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(block4.UndrlygCstmrCdtTrf.MT59F?.Acc, block4.UndrlygCstmrCdtTrf.MT59?.Acc, block4.UndrlygCstmrCdtTrf.MT59A?.Acc)
                        }
                    }
                }
            },
            InstrForNxtAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[0],
                    InstrInf: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[1]
                }
            ],
            InstrForCdtrAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[2],
                    InstrInf: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[3]
                }
            ],
            RmtInf: {Ustrd: [getRemmitanceInformation(block4.UndrlygCstmrCdtTrf.MT70?.Nrtv?.content)], Strd: []}
        }
    });
    return cdtTrfTxInfArray;
}

# This function transforms an MT203 SWIFT message into an ISO 20022 Pacs009Document.
#
# + message - The parsed MT203 message as a record value.
# + return - Returns a `Pacs009Document` if the transformation is successful, 
# otherwise returns an error.
isolated function transformMT203(swiftmt:MT203Message message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            CtrlSum: check convertToDecimal(message.block4.MT19.Amnt),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                },
                InstdRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT54A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT54D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT54D?.AdrsLine)
                        }
                    }
                },
                InstdRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT54A?.PrtyIdn, message.block4.MT54B?.PrtyIdn, message.block4.MT54D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT54A?.PrtyIdn, prtyIdn2 = message.block4.MT54B?.PrtyIdn, prtyIdn3 = message.block4.MT54D?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: message.block4.Transaction.length().toString(),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: check getMT203CreditTransferTransactionInfo(message.block4, message.block3)
    }
};

# This function retrieves credit transfer transaction information from an MT203 message 
# and transforms it into an array of ISO 20022 `CreditTransferTransaction62` records.
#
# + block4 - The parsed block4 of MT203 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT203 SWIFT message containing end to end id.
# + return - Returns an array of `CreditTransferTransaction62` records containing 
# details of the transactions, or an error if the transformation fails.
isolated function getMT203CreditTransferTransactionInfo(swiftmt:MT203Block4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:CreditTransferTransaction62[]|error {
    pacsIsoRecord:CreditTransferTransaction62[] cdtTrfTxInfArray = [];
    foreach swiftmt:MT203Transaction transaxion in block4.Transaction {
        swiftmt:MT72? sndToRcvrInfo = getMT203RepeatingFields(block4, transaxion.MT72, "72");
        cdtTrfTxInfArray.push({
            Cdtr: {FinInstnId: {}},
            CdtrAgt: {
                FinInstnId: {
                    BICFI: transaxion.MT58A?.IdnCd?.content,
                    LEI: getPartyIdentifier(transaxion.MT58A?.PrtyIdn, transaxion.MT58D?.PrtyIdn),
                    Nm: getName(transaxion.MT58D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(transaxion.MT58D?.AdrsLine)
                    }
                }
            },
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            IntrBkSttlmDt: convertToISOStandardDate(block4.MT30.Dt),
            PmtId: {
                EndToEndId: transaxion.MT21.Ref.content,
                InstrId: transaxion.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value
            },
            Dbtr: {FinInstnId: {}},
            DbtrAgt: {
                FinInstnId: {
                    BICFI: block4.MT52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(block4.MT52A?.PrtyIdn, block4.MT52D?.PrtyIdn),
                    Nm: getName(block4.MT52D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(block4.MT52D?.AdrsLine)
                    }
                }
            },
            IntrmyAgt1: getIntermediaryAgent1(transaxion.MT56A, transaxion.MT56D, transaxion.MT57A, transaxion.MT57B, transaxion.MT57D),
            IntrmyAgt2: getIntermediaryAgent2(transaxion.MT56A, transaxion.MT56D, transaxion.MT57A, transaxion.MT57B, transaxion.MT57D),
            InstrForNxtAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[0],
                    InstrInf: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[1]
                }
            ],
            InstrForCdtrAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[2],
                    InstrInf: getMT2XXSenderToReceiverInformation(sndToRcvrInfo)[3]
                }
            ]
        });
    }
    return cdtTrfTxInfArray;
}

# This function transforms an MT204 message into an ISO 20022 `Pacs010Document`.
#
# + message - The parsed MT204 message as record value.
# + return - Returns a `Pacs010Document` containing the direct debit transaction instructions,
# or an error if the transformation fails.
isolated function transformMT204(swiftmt:MT204Message message) returns pacsIsoRecord:Pacs010Document|error => {
    FIDrctDbt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            NbOfTxs: message.block4.Transaction.length().toString(),
            MsgId: uuid:createType4AsString().substring(0, 35),
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            }
        },
        CdtInstr: [
            {
                Cdtr: {
                    FinInstnId: {
                        BICFI: message.block4.MT58A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT58A?.PrtyIdn, message.block4.MT58D?.PrtyIdn),
                        Nm: getName(message.block4.MT58D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT58D?.AdrsLine)
                        }
                    }
                },
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn, message.block4.MT57B?.PrtyIdn, message.block4.MT57D?.PrtyIdn),
                        Nm: getName(message.block4.MT57D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT57D?.AdrsLine)
                        }
                    }
                },
                CdtId: message.block4.MT20.msgId.content,
                TtlIntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT19.Amnt),
                        Ccy: ""
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT30.Dt),
                InstrForCdtrAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                DrctDbtTxInf: check getMT204CreditTransferTransactionInfo(message.block4, message.block3)
            }
        ]
    }
};

# This function extracts direct debit transaction information from an MT204 message 
# and converts it into an array of ISO 20022 `DirectDebitTransactionInformation33` records.
#
# + block4 - The parsed block4 of MT204 SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT204 SWIFT message containing end to end id.
# + return - Returns an array of `DirectDebitTransactionInformation33` containing 
# the transaction information, or an error if the extraction fails.
isolated function getMT204CreditTransferTransactionInfo(swiftmt:MT204Block4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:DirectDebitTransactionInformation33[]|error {
    pacsIsoRecord:DirectDebitTransactionInformation33[] dbtTrfTxInfArray = [];
    foreach swiftmt:MT204Transaction transaxion in block4.Transaction {
        dbtTrfTxInfArray.push({
            IntrBkSttlmAmt: {
                ActiveCurrencyAndAmount_SimpleType: {
                    ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(transaxion.MT32B.Amnt),
                    Ccy: transaxion.MT32B.Ccy.content
                }
            },
            PmtId: {
                EndToEndId: getMandatoryFields(transaxion.MT21?.Ref?.content),
                InstrId: transaxion.MT20.msgId.content,
                UETR: block3?.NdToNdTxRef?.value
            },
            Dbtr: {
                FinInstnId: {
                    BICFI: transaxion.MT53A?.IdnCd?.content,
                    LEI: getPartyIdentifierOrAccount2(transaxion.MT53A?.PrtyIdn, transaxion.MT53B?.PrtyIdn, transaxion.MT53D?.PrtyIdn)[0],
                    Nm: getName(transaxion.MT53D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(transaxion.MT53D?.AdrsLine)
                    }
                }
            },
            InstrForDbtrAgt: getMT204SenderToReceiverInformation(transaxion.MT72)[0]
        });
    }
    return dbtTrfTxInfArray;
}

# This function transforms an MT205 message into an ISO 20022 `Pacs009Document`.
#
# + message - The parsed MT205 message as a record type.
# + return - Returns a `Pacs009Document` containing the payment instruction information, 
# or an error if the transformation fails.
isolated function transformMT205(swiftmt:MT205Message message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: [
            {
                Cdtr: {
                    FinInstnId: {
                        BICFI: message.block4.MT58A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT58A?.PrtyIdn, message.block4.MT58D?.PrtyIdn),
                        Nm: getName(message.block4.MT58D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT58D?.AdrsLine)
                        }
                    }
                },
                CdtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT57A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT57A?.PrtyIdn, message.block4.MT57B?.PrtyIdn, message.block4.MT57D?.PrtyIdn),
                        Nm: getName(message.block4.MT57D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT57D?.AdrsLine)
                        }
                    }
                },
                IntrBkSttlmAmt: {
                    ActiveCurrencyAndAmount_SimpleType: {
                        ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                        Ccy: message.block4.MT32A.Ccy.content
                    }
                },
                IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt),
                PmtId: {
                    EndToEndId: message.block4.MT21.Ref.content,
                    InstrId: message.block4.MT20.msgId.content,
                    UETR: message.block3?.NdToNdTxRef?.value
                },
                SttlmTmReq: {
                    CLSTm: getTimeIndication(message.block4.MT13C)[0]
                },
                SttlmTmIndctn: {
                    CdtDtTm: getTimeIndication(message.block4.MT13C)[1],
                    DbtDtTm: getTimeIndication(message.block4.MT13C)[2]
                },
                Dbtr: {FinInstnId: {}},
                DbtrAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT52A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                        Nm: getName(message.block4.MT52D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                        }
                    }
                },
                IntrmyAgt1: {
                    FinInstnId: {
                        BICFI: message.block4.MT56A?.IdnCd?.content,
                        LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                        Nm: getName(message.block4.MT56D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                        }
                    }
                },
                InstrForNxtAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[0],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[1]
                    }
                ],
                InstrForCdtrAgt: [
                    {
                        Cd: getMT2XXSenderToReceiverInformation(message.block4.MT72)[2],
                        InstrInf: getMT2XXSenderToReceiverInformation(message.block4.MT72)[3]
                    }
                ]
            }
        ]
    }
};

# This function transforms an MT205COV message into an ISO 20022 `Pacs009Document`.
#
# + message - The parsed MT205COV message as a record value.
# + return - Returns a `Pacs009Document` containing the payment instruction information, 
# or an error if the transformation fails.
isolated function transformMT205COV(swiftmt:MT205COVMessage message) returns pacsIsoRecord:Pacs009Document|error => {
    FICdtTrf: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            SttlmInf: {
                SttlmMtd: getSettlementMethod(message.block4.MT53A, message.block4.MT53B, message.block4.MT53D),
                InstgRmbrsmntAgt: {
                    FinInstnId: {
                        BICFI: message.block4.MT53A?.IdnCd?.content,
                        LEI: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[0],
                        Nm: getName(message.block4.MT53D?.Nm),
                        PstlAdr: {
                            AdrLine: getAddressLine(message.block4.MT53D?.AdrsLine)
                        }
                    }
                },
                InstgRmbrsmntAgtAcct: {
                    Id: {
                        IBAN: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[1],
                        Othr: {
                            Id: getPartyIdentifierOrAccount2(message.block4.MT53A?.PrtyIdn, message.block4.MT53B?.PrtyIdn, message.block4.MT53D?.PrtyIdn)[2],
                            SchmeNm: {
                                Cd: getSchemaCode(prtyIdn1 = message.block4.MT53A?.PrtyIdn, prtyIdn2 = message.block4.MT53B?.PrtyIdn, prtyIdn3 = message.block4.MT53D?.PrtyIdn)
                            }
                        }
                    }
                }
            },
            InstgAgt: {
                FinInstnId: {
                    BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                }
            },
            InstdAgt: {
                FinInstnId: {
                    BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                }
            },
            NbOfTxs: DEFAULT_NUM_OF_TX,
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        CdtTrfTxInf: check getMT205COVCreditTransfer(message.block4, message.block3)
    }
};

# This function extracts credit transfer transaction details from an MT205COV message and returns an array of 
# `CreditTransferTransaction62` records for ISO 20022.
#
# + block4 - The parsed block4 of MT205 COV SWIFT message containing multiple transactions.
# + block3 - The parsed block3 of MT205 COV SWIFT message containing end to end id.
# + return - Returns an array of `camtIsoRecord:CreditTransferTransaction62` containing the credit transfer 
# transaction information, or an error if the extraction fails.
isolated function getMT205COVCreditTransfer(swiftmt:MT205COVBlock4 block4, swiftmt:Block3? block3) returns pacsIsoRecord:CreditTransferTransaction62[]|error {
    pacsIsoRecord:CreditTransferTransaction62[] cdtTrfTxInfArray = [];
    cdtTrfTxInfArray.push({
        Cdtr: {FinInstnId: {}},
        CdtrAgt: {
            FinInstnId: {
                BICFI: block4.MT58A?.IdnCd?.content,
                LEI: getPartyIdentifier(block4.MT58A?.PrtyIdn, block4.MT58D?.PrtyIdn),
                Nm: getName(block4.MT58D?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.MT58D?.AdrsLine)
                }
            }
        },
        IntrBkSttlmAmt: {
            ActiveCurrencyAndAmount_SimpleType: {
                ActiveCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(block4.MT32A.Amnt),
                Ccy: block4.MT32A.Ccy.content
            }
        },
        IntrBkSttlmDt: convertToISOStandardDate(block4.MT32A.Dt),
        PmtId: {
            EndToEndId: block4.MT21.Ref.content,
            InstrId: block4.MT20.msgId.content,
            UETR: block3?.NdToNdTxRef?.value,
            TxId: block4.MT21.Ref.content
        },
        SttlmTmReq: {
            CLSTm: getTimeIndication(block4.MT13C)[0]
        },
        SttlmTmIndctn: {
            CdtDtTm: getTimeIndication(block4.MT13C)[1],
            DbtDtTm: getTimeIndication(block4.MT13C)[2]
        },
        Dbtr: {FinInstnId: {}},
        DbtrAgt: {
            FinInstnId: {
                BICFI: block4.MT52A?.IdnCd?.content,
                LEI: getPartyIdentifier(block4.MT52A?.PrtyIdn, block4.MT52D?.PrtyIdn),
                Nm: getName(block4.MT52D?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.MT52D?.AdrsLine)
                }
            }
        },
        IntrmyAgt1: getIntermediaryAgent1(block4.MT56A, block4.MT56D, block4.MT57A, block4.MT57B, block4.MT57D),
        IntrmyAgt2: getIntermediaryAgent2(block4.MT56A, block4.MT56D, block4.MT57A, block4.MT57B, block4.MT57D),
        InstrForNxtAgt: [
            {
                Cd: getMT2XXSenderToReceiverInformation(block4.MT72)[0],
                InstrInf: getMT2XXSenderToReceiverInformation(block4.MT72)[1]
            }
        ],
        InstrForCdtrAgt: [
            {
                Cd: getMT2XXSenderToReceiverInformation(block4.MT72)[2],
                InstrInf: getMT2XXSenderToReceiverInformation(block4.MT72)[3]
            }
        ],
        UndrlygCstmrCdtTrf: {
            Dbtr: {
                Id: {
                    OrgId: {
                        AnyBIC: block4.UndrlygCstmrCdtTrf.MT50A?.IdnCd?.content
                    },
                    PrvtId: {
                        Othr: [
                            {
                                Id: getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[0],
                                SchmeNm: {
                                    Cd: getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[3]
                                },
                                Issr: getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[4]
                            }
                        ]
                    }
                },
                Nm: getName(block4.UndrlygCstmrCdtTrf.MT50F?.Nm, block4.UndrlygCstmrCdtTrf.MT50K?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.UndrlygCstmrCdtTrf.MT50F?.AdrsLine, block4.UndrlygCstmrCdtTrf.MT50K?.AdrsLine),
                    Ctry: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT50F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT50F?.CntyNTw)[1]
                }
            },
            DbtrAcct: {
                Id: {
                    IBAN: getAccountId(validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT50A?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT50K?.Acc)[0], getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[1]),
                    Othr: {
                        Id: getAccountId(validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT50A?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT50K?.Acc)[1], getPartyIdentifierOrAccount(block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)[2]),
                        SchmeNm: {
                            Cd: getSchemaCode(block4.UndrlygCstmrCdtTrf.MT50A?.Acc, block4.UndrlygCstmrCdtTrf.MT50K?.Acc, prtyIdn1 = block4.UndrlygCstmrCdtTrf.MT50F?.PrtyIdn)
                        }
                    }
                }
            },
            DbtrAgt: {
                FinInstnId: {
                    BICFI: block4.UndrlygCstmrCdtTrf.MT52A?.IdnCd?.content,
                    LEI: getPartyIdentifier(block4.UndrlygCstmrCdtTrf.MT52A?.PrtyIdn, block4.UndrlygCstmrCdtTrf.MT52D?.PrtyIdn),
                    Nm: getName(block4.UndrlygCstmrCdtTrf.MT52D?.Nm),
                    PstlAdr: {
                        AdrLine: getAddressLine(block4.UndrlygCstmrCdtTrf.MT52D?.AdrsLine)
                    }
                }
            },
            InstdAmt: {
                ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                    ActiveOrHistoricCurrencyAndAmount_SimpleType: check getInstructedAmount(instrdAmnt = block4.UndrlygCstmrCdtTrf.MT33B),
                    Ccy: getMandatoryFields(block4.UndrlygCstmrCdtTrf.MT33B?.Ccy?.content)
                }
            },
            IntrmyAgt1: getIntermediaryAgent1(block4.UndrlygCstmrCdtTrf.MT56A, block4.UndrlygCstmrCdtTrf.MT56D, block4.UndrlygCstmrCdtTrf.MT57A, block4.UndrlygCstmrCdtTrf.MT57B, block4.UndrlygCstmrCdtTrf.MT57D),
            IntrmyAgt2: getIntermediaryAgent2(block4.UndrlygCstmrCdtTrf.MT56A, block4.UndrlygCstmrCdtTrf.MT56D, block4.UndrlygCstmrCdtTrf.MT57A, block4.UndrlygCstmrCdtTrf.MT57B, block4.UndrlygCstmrCdtTrf.MT57D),
            CdtrAgt: {FinInstnId: {}},
            Cdtr: {
                Id: {
                    OrgId: {
                        AnyBIC: block4.UndrlygCstmrCdtTrf.MT59A?.IdnCd?.content
                    }
                },
                Nm: getName(block4.UndrlygCstmrCdtTrf.MT59F?.Nm, block4.UndrlygCstmrCdtTrf.MT59?.Nm),
                PstlAdr: {
                    AdrLine: getAddressLine(block4.UndrlygCstmrCdtTrf.MT59F?.AdrsLine, block4.UndrlygCstmrCdtTrf.MT59?.AdrsLine),
                    Ctry: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT59F?.CntyNTw)[0],
                    TwnNm: getCountryAndTown(block4.UndrlygCstmrCdtTrf.MT59F?.CntyNTw)[1]
                }
            },
            CdtrAcct: {
                Id: {
                    IBAN: validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT59F?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT59?.Acc, acc3 = block4.UndrlygCstmrCdtTrf.MT59A?.Acc)[0],
                    Othr: {
                        Id: validateAccountNumber(block4.UndrlygCstmrCdtTrf.MT59F?.Acc, acc2 = block4.UndrlygCstmrCdtTrf.MT59?.Acc, acc3 = block4.UndrlygCstmrCdtTrf.MT59A?.Acc)[1],
                        SchmeNm: {
                            Cd: getSchemaCode(block4.UndrlygCstmrCdtTrf.MT59F?.Acc, block4.UndrlygCstmrCdtTrf.MT59?.Acc, block4.UndrlygCstmrCdtTrf.MT59A?.Acc)
                        }
                    }
                }
            },
            InstrForNxtAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[0],
                    InstrInf: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[1]
                }
            ],
            InstrForCdtrAgt: [
                {
                    Cd: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[2],
                    InstrInf: getMT2XXSenderToReceiverInformation(block4.UndrlygCstmrCdtTrf.MT72)[3]
                }
            ],
            RmtInf: {Ustrd: [getRemmitanceInformation(block4.UndrlygCstmrCdtTrf.MT70?.Nrtv?.content)], Strd: []}
        }
    });
    return cdtTrfTxInfArray;
}

# Transforms an MT210 message into an ISO 20022 Camt.057Document format.
#
# + message - The parsed MT210 message of type `swiftmt:MT210Message`.
# + return - Returns an ISO 20022 Camt.057Document or an error if the transformation fails.
isolated function transformMT210(swiftmt:MT210Message message) returns camtIsoRecord:Camt057Document|error => {
    NtfctnToRcv: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Ntfctn: {
            Itm: [
                {
                    Id: message.block4.MT20.msgId.content,
                    EndToEndId: message.block4.MT21.Ref.content,
                    UETR: message.block3?.NdToNdTxRef?.value,
                    Acct: {
                        Id: {
                            IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                            Othr: {
                                Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                                SchmeNm: {
                                    Cd: getSchemaCode(message.block4.MT25?.Acc)
                                }
                            }
                        }
                    },
                    Dbtr: {
                        Pty: {
                            Nm: getName(message.block4.MT50?.Nm, message.block4.MT50F?.Nm),
                            Id: {
                                OrgId: {
                                    AnyBIC: message.block4.MT50C?.IdnCd?.content
                                },
                                PrvtId: {
                                    Othr: [
                                        {
                                            Id: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[0],
                                            SchmeNm: {
                                                Cd: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[3]
                                            },
                                            Issr: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[4]
                                        }
                                    ]
                                }
                            },
                            PstlAdr: {
                                AdrLine: getAddressLine(message.block4.MT50F?.AdrsLine),
                                Ctry: getCountryAndTown(message.block4.MT50F?.CntyNTw)[0],
                                TwnNm: getCountryAndTown(message.block4.MT50F?.CntyNTw)[1]
                            }
                        }
                    },
                    DbtrAgt: {
                        FinInstnId: {
                            BICFI: message.block4.MT52A?.IdnCd?.content,
                            LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                            Nm: getName(message.block4.MT52D?.Nm),
                            PstlAdr: {
                                AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                            }
                        }
                    },
                    IntrmyAgt: {
                        FinInstnId: {
                            BICFI: message.block4.MT56A?.IdnCd?.content,
                            LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                            Nm: getName(message.block4.MT56D?.Nm),
                            PstlAdr: {
                                AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                            }
                        }
                    },
                    Amt: {
                        ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                            ActiveOrHistoricCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32B.Amnt),
                            Ccy: message.block4.MT32B.Ccy.content
                        }
                    }
                }
            ],
            Id: message.block4.MT20.msgId.content
        }
    }
};

# This function transforms an MT900 SWIFT message into an ISO 20022 CAMT.054 document.
# The MT900 message contains debit confirmation details, which are mapped to a notification
# in the CAMT.054 format, including account information, transaction details, and amounts.
#
# + message - The parsed MT900 message as a record value.
# + return - Returns a `Camt054Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT900(swiftmt:MT900Message message) returns camtIsoRecord:Camt054Document|error => {
    BkToCstmrDbtCdtNtfctn: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Ntfctn: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc, message.block4.MT25P?.Acc)
                            }
                        }
                    },
                    Ownr: {
                        Id: {
                            OrgId: {
                                AnyBIC: message.block4.MT25P?.IdnCd?.content
                            }
                        }
                    }
                },
                CreDtTm: convertToISOStandardDateTime(message.block4.MT13D?.Dt, message.block4.MT13D?.Tm),
                Ntry: [
                    {
                        Amt: {
                            ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                                ActiveOrHistoricCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                                Ccy: message.block4.MT32A.Ccy.content
                            }
                        },
                        CdtDbtInd: camtIsoRecord:DBIT,
                        ValDt: {
                            Dt: convertToISOStandardDate(message.block4.MT32A.Dt)
                        },
                        Sts: {},
                        BkTxCd: {},
                        NtryDtls: [
                            {
                                TxDtls: [
                                    {
                                        Amt: {
                                            ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                                                ActiveOrHistoricCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                                                Ccy: message.block4.MT32A.Ccy.content
                                            }
                                        },
                                        CdtDbtInd: camtIsoRecord:DBIT,
                                        RltdAgts: {
                                            DbtrAgt: {
                                                FinInstnId: {
                                                    BICFI: message.block4.MT52A?.IdnCd?.content,
                                                    LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                                                    Nm: getName(message.block4.MT52D?.Nm),
                                                    PstlAdr: {
                                                        AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
};

# This function transforms an MT910 SWIFT message into an ISO 20022 CAMT.054 document format. 
# It extracts details from the MT910 message and maps them to the CAMT structure.
#
# + message - The parsed MT910 message as a record value.
# + return - Returns a `Camt054Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT910(swiftmt:MT910Message message) returns camtIsoRecord:Camt054Document|error => {
    BkToCstmrDbtCdtNtfctn: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Ntfctn: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc, message.block4.MT25P?.Acc)
                            }
                        }
                    },
                    Ownr: {
                        Id: {
                            OrgId: {
                                AnyBIC: message.block4.MT25P?.IdnCd?.content
                            }
                        }
                    }
                },
                CreDtTm: convertToISOStandardDateTime(message.block4.MT13D?.Dt, message.block4.MT13D?.Tm),
                Ntry: [
                    {
                        Amt: {
                            ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                                ActiveOrHistoricCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                                Ccy: message.block4.MT32A.Ccy.content
                            }
                        },
                        CdtDbtInd: camtIsoRecord:CRDT,
                        ValDt: {
                            Dt: convertToISOStandardDate(message.block4.MT32A.Dt)
                        },
                        Sts: {},
                        BkTxCd: {},
                        NtryDtls: [
                            {
                                TxDtls: [
                                    {
                                        Amt: {
                                            ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                                                ActiveOrHistoricCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                                                Ccy: message.block4.MT32A.Ccy.content
                                            }
                                        },
                                        CdtDbtInd: camtIsoRecord:CRDT,
                                        RltdAgts: {
                                            DbtrAgt: {
                                                FinInstnId: {
                                                    BICFI: message.block4.MT52A?.IdnCd?.content,
                                                    LEI: getPartyIdentifier(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn),
                                                    Nm: getName(message.block4.MT52D?.Nm),
                                                    PstlAdr: {
                                                        AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                                                    }
                                                }
                                            },
                                            IntrmyAgt1: {
                                                FinInstnId: {
                                                    BICFI: message.block4.MT56A?.IdnCd?.content,
                                                    LEI: getPartyIdentifier(message.block4.MT56A?.PrtyIdn, message.block4.MT56D?.PrtyIdn),
                                                    Nm: getName(message.block4.MT56D?.Nm),
                                                    PstlAdr: {
                                                        AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                                                    }
                                                }
                                            }
                                        },
                                        RltdPties: {
                                            Dbtr: {
                                                Pty: {
                                                    Id: {
                                                        OrgId: {
                                                            AnyBIC: message.block4.MT50A?.IdnCd?.content
                                                        },
                                                        PrvtId: {
                                                            Othr: [
                                                                {
                                                                    Id: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[0],
                                                                    SchmeNm: {
                                                                        Cd: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[3]
                                                                    },
                                                                    Issr: getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[4]
                                                                }
                                                            ]
                                                        }
                                                    },
                                                    Nm: getName(message.block4.MT50F?.Nm, message.block4.MT50K?.Nm),
                                                    PstlAdr: {
                                                        AdrLine: getAddressLine(message.block4.MT50F?.AdrsLine, message.block4.MT50K?.AdrsLine),
                                                        Ctry: getCountryAndTown(message.block4.MT50F?.CntyNTw)[0],
                                                        TwnNm: getCountryAndTown(message.block4.MT50F?.CntyNTw)[1]
                                                    }
                                                }
                                            },
                                            DbtrAcct: {
                                                Id: {
                                                    IBAN: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[0], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[1]),
                                                    Othr: {
                                                        Id: getAccountId(validateAccountNumber(message.block4.MT50A?.Acc, acc2 = message.block4.MT50K?.Acc)[1], getPartyIdentifierOrAccount(message.block4.MT50F?.PrtyIdn)[2]),
                                                        SchmeNm: {
                                                            Cd: getSchemaCode(message.block4.MT50A?.Acc, message.block4.MT50K?.Acc, prtyIdn1 = message.block4.MT50F?.PrtyIdn)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
};

# This function transforms an MT920 SWIFT message into an ISO 20022 CAMT.060 document format. 
# It extracts relevant fields from the MT920 message and maps them to the CAMT structure.
#
# + message - The parsed MT920 message as a record value.
# + return - Returns a `Camt060Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT920(swiftmt:MT920Message message) returns camtIsoRecord:Camt060Document|error => {
    AcctRptgReq: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        RptgReq: [
            {
                Id: message.block4.MT20.msgId.content,
                ReqdMsgNmId: message.block4.MT12.Msg.content,
                AcctOwnr: {},
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc)
                            }
                        }
                    }
                },
                ReqdTxTp: {
                    Sts: {},
                    CdtDbtInd: camtIsoRecord:DBIT,
                    FlrLmt: check getFloorLimit(message.block4.MT34F)
                }
            }
        ]
    }
};

# This function transforms an MT940 SWIFT message into an ISO 20022 CAMT.053 document.
# The relevant fields from the MT940 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT940 message as a record value.
# + return - Returns a `Camt053Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT940(swiftmt:MT940Message message) returns camtIsoRecord:Camt053Document|error => {
    BkToCstmrStmt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Stmt: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25P?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25P?.Acc)[1]
                        }
                    },
                    Ownr: {
                        Id: {
                            OrgId: {
                                AnyBIC: message.block4.MT25P?.IdnCd?.content
                            }
                        }
                    }
                },
                ElctrncSeqNb: message.block4.MT28C.SeqNo?.content,
                Bal: check getBalance(message.block4.MT60F, message.block4.MT62F, message.block4.MT64, message.block4.MT60M, message.block4.MT62M, message.block4.MT65),
                Ntry: check getEntries(message.block4.MT61)
            }
        ]
    }
};

# This function transforms an MT941 SWIFT message into an ISO 20022 CAMT.052 document.
# The relevant fields from the MT941 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT941 message as a record value.
# + return - Returns a `Camt052Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT941(swiftmt:MT941Message message) returns camtIsoRecord:Camt052Document|error => {
    BkToCstmrAcctRpt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Rpt: [
            {
                Id: message.block4.MT20.msgId.content,
                CreDtTm: convertToISOStandardDateTime(message.block4.MT13D?.Dt, message.block4.MT13D?.Tm),
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc, message.block4.MT25P?.Acc)
                            }
                        }
                    }
                },
                ElctrncSeqNb: message.block4.MT28.SeqNo?.content,
                Bal: check getBalance(message.block4.MT60F, message.block4.MT62F, message.block4.MT64, forwardAvailableBalance = message.block4.MT65),
                TxsSummry: {
                    TtlNtries: {
                        NbOfNtries: check getTotalNumOfEntries(message.block4.MT90C?.TtlNum, message.block4.MT90D?.TtlNum),
                        Sum: check getTotalSumOfEntries(message.block4.MT90C?.Amnt, message.block4.MT90D?.Amnt)
                    },
                    TtlDbtNtries: {
                        NbOfNtries: message.block4.MT90D?.TtlNum?.content,
                        Sum: check convertToDecimal(message.block4.MT90D?.Amnt)
                    },
                    TtlCdtNtries: {
                        NbOfNtries: message.block4.MT90C?.TtlNum?.content,
                        Sum: check convertToDecimal(message.block4.MT90C?.Amnt)
                    }
                },
                AddtlRptInf: getInfoToAccOwnr(message.block4.MT86)
            }
        ]
    }
};

# This function transforms an MT942 SWIFT message into an ISO 20022 CAMT.052 document.
# The relevant fields from the MT942 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT942 message as a record value.
# + return - Returns a `Camt052Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT942(swiftmt:MT942Message message) returns camtIsoRecord:Camt052Document|error => {
    BkToCstmrAcctRpt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Rpt: [
            {
                Id: message.block4.MT20.msgId.content,
                CreDtTm: convertToISOStandardDateTime(message.block4.MT13D?.Dt, message.block4.MT13D?.Tm),
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc, acc2 = message.block4.MT25P?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc, message.block4.MT25P?.Acc)
                            }
                        }
                    }
                },
                ElctrncSeqNb: message.block4.MT28C.SeqNo?.content,
                Ntry: check getEntries(message.block4.MT61),
                TxsSummry: {
                    TtlNtries: {
                        NbOfNtries: check getTotalNumOfEntries(message.block4.MT90C?.TtlNum, message.block4.MT90D?.TtlNum),
                        Sum: check getTotalSumOfEntries(message.block4.MT90C?.Amnt, message.block4.MT90D?.Amnt)
                    },
                    TtlDbtNtries: {
                        NbOfNtries: message.block4.MT90D?.TtlNum?.content,
                        Sum: check convertToDecimal(message.block4.MT90D?.Amnt)
                    },
                    TtlCdtNtries: {
                        NbOfNtries: message.block4.MT90C?.TtlNum?.content,
                        Sum: check convertToDecimal(message.block4.MT90C?.Amnt)
                    }
                },
                AddtlRptInf: getInfoToAccOwnr(message.block4.MT86)
            }
        ]
    }
};

# This function transforms an MT950 SWIFT message into an ISO 20022 CAMT.053 document.
# The relevant fields from the MT950 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT950 message as a record value.
# + return - Returns a `Camt053Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT950(swiftmt:MT950Message message) returns camtIsoRecord:Camt053Document|error => {
    BkToCstmrStmt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Stmt: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc)
                            }
                        }
                    }
                },
                ElctrncSeqNb: message.block4.MT28C.SeqNo?.content,
                Bal: check getBalance(message.block4.MT60F, message.block4.MT62F, message.block4.MT64, message.block4.MT60M, message.block4.MT62M),
                Ntry: check getEntries(message.block4.MT61)
            }
        ]
    }
};

# This function transforms an MT970 SWIFT message into an ISO 20022 CAMT.053 document.
# The relevant fields from the MT970 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT970 message as a record value.
# + return - Returns a `Camt053Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT970(swiftmt:MT970Message message) returns camtIsoRecord:Camt053Document|error => {
    BkToCstmrStmt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Stmt: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc)
                            }
                        }
                    }
                },
                ElctrncSeqNb: message.block4.MT28C.SeqNo?.content,
                Bal: check getBalance(message.block4.MT60F, message.block4.MT62F, message.block4.MT64, message.block4.MT60M, message.block4.MT62M),
                Ntry: check getEntries(message.block4.MT61)
            }
        ]
    }
};

# This function transforms an MT971 SWIFT message into an ISO 20022 CAMT.052 document.
# The relevant fields from the MT971 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT971 message as a record value.
# + return - Returns a `Camt052Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT971(swiftmt:MT971Message message) returns camtIsoRecord:Camt052Document|error => {
    BkToCstmrAcctRpt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Rpt: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc)
                            }
                        }
                    }
                },
                Bal: [
                    {
                        Amt: {
                            ActiveOrHistoricCurrencyAndAmount_SimpleType: {
                                ActiveOrHistoricCurrencyAndAmount_SimpleType: check convertToDecimalMandatory(message.block4.MT62F.Amnt),
                                Ccy: message.block4.MT62F.Ccy.content
                            }
                        },
                        Dt: {Dt: convertToISOStandardDate(message.block4.MT62F.Dt)},
                        CdtDbtInd: convertDbtOrCrdToISOStandard(message.block4.MT62F),
                        Tp: {
                            CdOrPrtry: {
                                Cd: "CLBD"
                            }
                        }
                    }
                ]
            }
        ]
    }
};

# This function transforms an MT972 SWIFT message into an ISO 20022 CAMT.052 document.
# The relevant fields from the MT972 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT972 message as a record value.
# + return - Returns a `Camt052Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT972(swiftmt:MT972Message message) returns camtIsoRecord:Camt052Document|error => {
    BkToCstmrAcctRpt: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        Rpt: [
            {
                Id: message.block4.MT20.msgId.content,
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc)
                            }
                        }
                    }
                },
                ElctrncSeqNb: message.block4.MT28C.SeqNo?.content,
                Bal: check getBalance(message.block4.MT60F, message.block4.MT62F, message.block4.MT64, message.block4.MT60M, message.block4.MT62M),
                Ntry: check getEntries(message.block4.MT61)
            }
        ]
    }
};

# This function transforms an MT973 SWIFT message (account reporting request) into an ISO 20022 CAMT.060 document.
# The relevant fields from the MT973 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT973 message as a record value.
# + return - Returns a `Camt060Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT973(swiftmt:MT973Message message) returns camtIsoRecord:Camt060Document|error => {
    AcctRptgReq: {
        GrpHdr: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            MsgId: uuid:createType4AsString().substring(0, 35)
        },
        RptgReq: [
            {
                Id: message.block4.MT20.msgId.content,
                ReqdMsgNmId: message.block4.MT12.Msg.content,
                AcctOwnr: {},
                Acct: {
                    Id: {
                        IBAN: validateAccountNumber(message.block4.MT25?.Acc)[0],
                        Othr: {
                            Id: validateAccountNumber(message.block4.MT25?.Acc)[1],
                            SchmeNm: {
                                Cd: getSchemaCode(message.block4.MT25?.Acc)
                            }
                        }
                    }
                }
            }
        ]
    }
};

# This function transforms an MT192 SWIFT message to a camt.055 ISO 20022 XML document format.
#
# This function performs the conversion of an MT192 SWIFT message to the corresponding
# ISO 20022 XML camt.055 format.
# The relevant fields from the MT192 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The MT192 message to be transformed, which should be in the `swiftmt:MTn92Message` format.
# + return - Returns a record in `camtIsoRecord:Camt055Document` format if successful, otherwise returns an error.
isolated function transformMT192ToCamt055(swiftmt:MTn92Message message) returns camtIsoRecord:Camt055Document|error =>{
    CstmrPmtCxlReq: {
        Assgnmt: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            Assgne: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                    }
                }
            },
            Id: ASSIGN_ID,
            Assgnr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Case: {
            Id: message.block4.MT20.msgId.content,
            Cretr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Undrlyg: [
            {
                OrgnlPmtInfAndCxl: [
                    {
                        OrgnlPmtInfId: message.block4.MT21.Ref.content,
                        CxlRsnInf: [
                            {
                                Rsn: {
                                    Cd: getCancellationReasonCode(message.block4.MT79)
                                },
                                AddtlInf: getAdditionalCancellationInfo(message.block4.MT79)
                            }
                        ]
                    }
                ]
            }
        ],
        SplmtryData: [
            {
                Envlp: {
                    CpOfOrgnlMsg: message.block4.MessageCopy.toJson()
                }
            }
        ]
    }
};

# This function transforms an MT292 or MT992 SWIFT message to a camt.056 ISO 20022 XML document format.
#
# This function performs the conversion of an MT292 or MT992 SWIFT message to the corresponding
# ISO 20022 XML camt.056 format.
# The relevant fields from the MT292 or MT992 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The MT292 or MT992 message to be transformed, which should be in the `swiftmt:MTn92Message` format.
# + return - Returns a record in `camtIsoRecord:Camt056Document` format if successful, otherwise returns an error.
isolated function transformMTn92ToCamt056(swiftmt:MTn92Message message) returns camtIsoRecord:Camt056Document|error => {
    FIToFIPmtCxlReq: {
        Assgnmt: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            Assgne: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                    }
                }
            },
            Id: ASSIGN_ID,
            Assgnr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Case: {
            Id: message.block4.MT20.msgId.content,
            Cretr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Undrlyg: [
            {
                TxInf: [
                    {
                        OrgnlInstrId: message.block4.MT21.Ref.content,
                        CxlRsnInf: [
                            {
                                Rsn: {
                                    Cd: getCancellationReasonCode(message.block4.MT79)
                                },
                                AddtlInf: getAdditionalCancellationInfo(message.block4.MT79)
                            }
                        ]
                    }
                ]
            }
        ],
        SplmtryData: [
            {
                Envlp: {
                    CpOfOrgnlMsg: message.block4.MessageCopy.toJson()
                }
            }
        ]
    }
};

# This function transforms an MTn95 SWIFT message to a camt.026 ISO 20022 XML document format.
#
# This function performs the conversion of an MTn95 SWIFT message to the corresponding
# ISO 20022 XML camt.026 format.
# The relevant fields from the MTn95 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The MTn95 message to be transformed, which should be in the `swiftmt:MTn95Message` format.
# + return - Returns a record in `camtIsoRecord:Camt026Document` format if successful, otherwise returns an error.
isolated function transformMTn95ToCamt026(swiftmt:MTn95Message message) returns camtIsoRecord:Camt026Document|error => {
    UblToApply: {
        Assgnmt: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            Assgne: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                    }
                }
            },
            Id: ASSIGN_ID,
            Assgnr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Case: {
            Id: message.block4.MT20.msgId.content,
            Cretr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Undrlyg: {
            Initn: {
                OrgnlInstrId: message.block4.MT21.Ref.content
            }
        },
        Justfn: {
            MssngOrIncrrctInf: getJustificationReason(message.block4.MT75.Nrtv.content)
        },
        SplmtryData: [
            {
                Envlp: {
                    CpOfOrgnlMsg: message.block4.MessageCopy.toJson(),
                    Nrtv: getDescriptionOfMessage(message.block4.MT79?.Nrtv)
                }
            }
        ]
    }
};

# This function transforms an MTn96 SWIFT message to a camt.028 ISO 20022 XML document format.
#
# This function performs the conversion of an MTn96 SWIFT message to the corresponding
# ISO 20022 XML camt.028 format.
# The relevant fields from the MTn96 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The MTn96 message to be transformed, which should be in the `swiftmt:MTn96Message` format.
# + return - Returns a record in `camtIsoRecord:Camt028Document` format if successful, otherwise returns an error.
isolated function transformMTn96ToCamt028(swiftmt:MTn96Message message) returns camtIsoRecord:Camt028Document|error => {
    AddtlPmtInf: {
        Assgnmt: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            Assgne: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                    }
                }
            },
            Id: ASSIGN_ID,
            Assgnr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Case: {
            Id: message.block4.MT20.msgId.content,
            Cretr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Undrlyg: {
            Initn: {
                OrgnlInstrId: message.block4.MT21.Ref.content
            }
        },
        Inf: {},
        SplmtryData: [
            {
                Envlp: {
                    CpOfOrgnlMsg: message.block4.MessageCopy.toJson(),
                    Nrtv: getDescriptionOfMessage(message.block4.MT79?.Nrtv)
                }
            },
            {
                Envlp: {
                    Nrtv: message.block4.MT76.Nrtv.content
                }
            }
        ]
    }
};

# This function transforms an MTn96 SWIFT message to a camt.031 ISO 20022 XML document format.
#
# This function performs the conversion of an MTn96 SWIFT message to the corresponding
# ISO 20022 XML camt.031 format.
# The relevant fields from the MTn96 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The MTn96 message to be transformed, which should be in the `swiftmt:MTn96Message` format.
# + return - Returns a record in `camtIsoRecord:Camt031Document` format if successful, otherwise returns an error.
isolated function transformMTn96ToCamt031(swiftmt:MTn96Message message) returns camtIsoRecord:Camt031Document|error => {
    RjctInvstgtn: {
        Assgnmt: {
            CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
            Assgne: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)
                    }
                }
            },
            Id: ASSIGN_ID,
            Assgnr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Case: {
            Id: message.block4.MT20.msgId.content,
            Cretr: {
                Agt: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)
                    }
                }
            }
        },
        Justfn: {
            RjctnRsn: check getRejectedReason(message.block4.MT76.Nrtv.content)
        },
        SplmtryData: [
            {
                Envlp: {
                    CpOfOrgnlMsg: message.block4.MessageCopy.toJson(),
                    Nrtv: getDescriptionOfMessage(message.block4.MT79?.Nrtv)
                }
            },
            {
                Envlp: {
                    Nrtv: message.block4.MT76.Nrtv.content
                }
            }
        ]
    }
};
