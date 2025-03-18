// Copyright (c) 2025, WSO2 LLC. (https://www.wso2.com).
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

# This function transforms an MT972 SWIFT message into an ISO 20022 CAMT.052 document.
# The relevant fields from the MT972 message are extracted and mapped to the corresponding ISO 20022 structure.
#
# + message - The parsed MT972 message as a record value.
# + return - Returns a `Camt052Document` object if the transformation is successful, otherwise returns an error.
isolated function transformMT972ToCamt052(swiftmt:MT972Message message) returns camtIsoRecord:Camt052Envelope|error =>
    let camtIsoRecord:ReportEntry14[] entries = check getEntries(message.block4.MT61) in {
        AppHdr: {
            Fr: {
                FIId: {
                    FinInstnId: {
                        BICFI: getMessageSender(message.block1?.logicalTerminal,
                                message.block2.MIRLogicalTerminal)
                    }
                }
            },
            To: {
                FIId: {
                    FinInstnId: {
                        BICFI: getMessageReceiver(message.block1?.logicalTerminal,
                                message.block2.receiverAddress)
                    }
                }
            },
            BizMsgIdr: message.block4.MT20.msgId.content,
            MsgDefIdr: "camt052.001.12",
            BizSvc: "swift.cbprplus.02",
            CreDt: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime,
                    true).ensureType(string) 
        },
        Document: {
            BkToCstmrAcctRpt: {
                GrpHdr: {
                    CreDtTm: check convertToISOStandardDateTime(message.block2.MIRDate, message.block2.senderInputTime,
                            true).ensureType(string) ,
                    MsgId: message.block4.MT20.msgId.content
                },
                Rpt: [
                    {
                        Id: message.block4.MT20.msgId.content,
                        Acct: getCashAccount(message.block4.MT25?.Acc, ()) ?: {},
                        ElctrncSeqNb: message.block4.MT28C.SeqNo?.content,
                        LglSeqNb: message.block4.MT28C.StmtNo.content,
                        Bal: check getBalance(message.block4.MT60F, message.block4.MT62F, message.block4.MT64,
                                message.block4.MT60M, message.block4.MT62M),
                        Ntry: entries.length() == 0 ? () : entries
                    }
                ]
            }
        }
    };
