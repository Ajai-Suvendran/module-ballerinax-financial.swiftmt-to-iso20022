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

# This function transforms an MT910 SWIFT message into an ISO 20022 CAMT.054 document format. 
# It extracts details from the MT910 message and maps them to the CAMT structure.
#
# + message - The parsed MT910 message as a record value.
# + return - Returns a `Camt054Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT910Camt054(swiftmt:MT910Message message) returns camtIsoRecord:Camt054Envelope|error => {
    AppHdr: {
        Fr: {FIId: {FinInstnId: {BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)}}}, 
        To: {FIId: {FinInstnId: {BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)}}}, 
        BizMsgIdr: message.block4.MT20.msgId.content, 
        MsgDefIdr: "camt054.001.12", 
        CreDt: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string)
    },
    Document: {
        BkToCstmrDbtCdtNtfctn: {
            GrpHdr: {
                CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
                MsgId: message.block4.MT20.msgId.content
            },
            Ntfctn: [{
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
                Ntry: [{
                        Amt: {
                            content: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                            Ccy: message.block4.MT32A.Ccy.content
                        },
                        CdtDbtInd: camtIsoRecord:CRDT,
                        ValDt: {
                            Dt: convertToISOStandardDate(message.block4.MT32A.Dt)
                        },
                        BookgDt: {
                            DtTm: convertToISOStandardDateTime(message.block4.MT13D?.Dt, message.block4.MT13D?.Tm) is () ? (): 
                            convertToISOStandardDateTime(message.block4.MT13D?.Dt, message.block4.MT13D?.Tm).toString()
                            + message.block4.MT13D?.Sgn?.content.toString() + message.block4.MT13D?.TmOfst?.content.toString().substring(0,2) + 
                            ":" + message.block4.MT13D?.TmOfst?.content.toString().substring(2)
                        },
                        Sts: {},
                        BkTxCd: {},
                        NtryDtls: [{
                            TxDtls: [{
                                    Amt: {
                                        content: check convertToDecimalMandatory(message.block4.MT32A.Amnt),
                                        Ccy: message.block4.MT32A.Ccy.content
                                    },
                                    RltdDts: {
                                        IntrBkSttlmDt: convertToISOStandardDate(message.block4.MT32A.Dt)
                                    },
                                    Refs: {
                                        EndToEndId: message.block4.MT21.Ref.content,
                                        InstrId: message.block4.MT21.Ref.content,
                                        UETR: message.block3?.NdToNdTxRef?.value
                                    },
                                    CdtDbtInd: camtIsoRecord:CRDT,
                                    RltdAgts: {
                                        DbtrAgt: getDebtorAgent2(message.block4),
                                        IntrmyAgt1: {
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
                                        }
                                    },
                                    RltdPties: {
                                        Dbtr: {
                                            Pty: getDebtor(message.block4),
                                            Agt: getDebtorAgent(message.block4)
                                        },
                                        DbtrAcct: getDebtorAccount(message.block4)
                                    },
                                    AddtlTxInf: message.block4.MT72?.Cd?.content
                            }]
                        }]
                }]
            }]
        }
    }
};
