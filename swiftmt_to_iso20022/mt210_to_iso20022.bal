// Copyright (c) 2024, WSO2 LLC. (https://www.wso2.com).
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

import ballerinax/financial.iso20022.cash_management as camtIsoRecord;
import ballerinax/financial.swift.mt as swiftmt;

# Transforms an MT210 message into an ISO 20022 Camt.057Document format.
#
# + message - The parsed MT210 message of type `swiftmt:MT210Message`.
# + return - Returns an ISO 20022 Camt.057Document or an error if the transformation fails.
isolated function transformMT210ToCamt057(swiftmt:MT210Message message) returns camtIsoRecord:Camt057Envelope|error => {
    AppHdr: {
        Fr: {FIId: {FinInstnId: {BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)}}}, 
        To: {FIId: {FinInstnId: {BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)}}}, 
        BizMsgIdr: message.block4.MT20.msgId.content, 
        MsgDefIdr: "camt.057.001.08", 
        CreDt: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string)
    },
    Document: {
        NtfctnToRcv: {
            GrpHdr: {
                CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
                MsgId: message.block4.MT20.msgId.content
            },
            Ntfctn: {
                Itm: [
                    {
                        Id: message.block4.MT21.Ref.content,
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
                                ClrSysMmbId: {
                                    MmbId: "", 
                                    ClrSysId: {
                                        Cd: getPartyIdentifierOrAccount2(message.block4.MT52A?.PrtyIdn, message.block4.MT52D?.PrtyIdn)[0]
                                    }
                                },
                                Nm: getName(message.block4.MT52D?.Nm),
                                PstlAdr: {
                                    AdrLine: getAddressLine(message.block4.MT52D?.AdrsLine)
                                }
                            }
                        },
                        IntrmyAgt: {
                            FinInstnId: {
                                BICFI: message.block4.MT56A?.IdnCd?.content,
                                ClrSysMmbId: {
                                    MmbId: "", 
                                    ClrSysId: {
                                        Cd: getPartyIdentifierOrAccount2(message.block4.MT56A?.PrtyIdn, message.block4.MT56D?.PrtyIdn)[0]
                                    }
                                },
                                Nm: getName(message.block4.MT56D?.Nm),
                                PstlAdr: {
                                    AdrLine: getAddressLine(message.block4.MT56D?.AdrsLine)
                                }
                            }
                        },
                        Amt: {
                            content: check convertToDecimalMandatory(message.block4.MT32B.Amnt),
                            Ccy: message.block4.MT32B.Ccy.content
                        },
                        XpctdValDt: convertToISOStandardDate(message.block4.MT30?.Dt)
                    }
                ],
                Id: message.block4.MT20.msgId.content
            }
        }
    }
};
