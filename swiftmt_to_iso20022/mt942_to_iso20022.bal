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

# This function transforms an MT942 SWIFT message into an ISO 20022 CAMT.052 document.
# The relevant fields from the MT942 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT942 message as a record value.
# + return - Returns a `Camt052Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT942ToCamt052(swiftmt:MT942Message message) returns camtIsoRecord:Camt052Envelope|error => {
    AppHdr: {
        Fr: {FIId: {FinInstnId: {BICFI: getMessageSender(message.block1?.logicalTerminal, message.block2.MIRLogicalTerminal)}}}, 
        To: {FIId: {FinInstnId: {BICFI: getMessageReceiver(message.block1?.logicalTerminal, message.block2.receiverAddress)}}}, 
        BizMsgIdr: message.block4.MT20.msgId.content, 
        MsgDefIdr: "camt052.001.12", 
        CreDt: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string)
    },
    Document: {
        BkToCstmrAcctRpt: {
            GrpHdr: {
                CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime, true).ensureType(string),
                MsgId: message.block4.MT20.msgId.content
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
                    LglSeqNb: message.block4.MT28C.StmtNo.content,
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
    }
};
