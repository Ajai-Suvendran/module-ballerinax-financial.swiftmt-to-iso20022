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

const DETAILS_CHRGS = [["BEN", "CRED"], ["OUR", "DEBT"], ["SHA", "SHAR"]];
const DEFAULT_NUM_OF_TX = "1";
const YEAR_PREFIX = "20";
const ASSIGN_ID = "ASSIGNID-01";
const SCHEMA_CODE = ["ARNU", "CCPT", "CUST", "DRLC", "EMPL", "NIDN", "SOSE", "TXID"];
const REASON_CODE = ["AGNT", "AM09", "COVR", "CURR", "CUST", "CUTA", "DUPL", "FRAD", "TECH", "UPAY"];
const MT_1XX_SNDR_CODE = ["INT", "ACC", "INS", "INTA", "SVCLVL", "LOCINS", "CATPURP"];
const MT_2XX_SNDR_CODE1 = ["INT", "ACC", "INS", "BNF", "TSU", "INTA", "PHON", "PHONBEN", "PHONIBK", "TELE", 
            "TELEBEN", "TELEIBK", "SVCLVL", "LOCINS", "CATPURP", "PURP", "UDLC"];
const MT_2XX_SNDR_CODE2 = ["INT", "ACC", "PHON", "PHONIBK", "TELE", "TELEIBK"];
const MT_2XX_SNDR_CODE3 = ["ACC", "BNF"];
const MISSING_INFO_CODE = ["3", "4", "5", "7", "10", "13", "14", "15", "16", "17", "18", "19", "23", "24", "25", "26",
    "27", "28", "29", "36", "37", "38", "42", "48", "49", "50", "51"];
const INCORRECT_INFO_CODE = ["2", "6", "8", "9", "11", "12", "20", "22", "39", "40", "41", "43", "44", "45", "46",
    "47"];
const map<string> INVTGTN_RJCT_RSN = {"RQDA": "NAUT", "LEGL": "NAUT", "INDM": "NAUT", "AGNT": "NAUT", "CUST": "NAUT",
    "NOOR": "NFND", "PTNA": "UKNW", "ARPL": "UKNW", "NOAS": "UKNW", "AM04": "PCOR", "AC04": "PCOR", "ARDT": "UKNW"};
const RTND_CODE = "RTND";
const UNSUPPORTED_MSG = "Return general direct debit transfer message is not supported.";
const CANCEL_CODE = "CNCL";
const PENDING_CANCEL_CODE = "PDCR";
const REJECT_CODE = "RJCR";
const AUTH_CODE = "AUTH";
const NAUT_CODE = "NAUT";
const OTHR_CODE = "OTHR";
const RFDD_CODE = "RFDD";
const DECIMAL_ERROR = "Invalid decimal format in amount/rate. Expected format: nn,nn or nn,n";
const XML_NAMESPACE_ISO = "urn:iso:std:iso:20022:tech:xsd";
const XML_NAMESPACE_SWIFT = "urn:swift:xsd:envelope";
const XML_NAMESPACE_XSI = "http://www.w3.org/2001/XMLSchema-instance";
const APP_HDR_VERSION = "head.001.001.02";
const IBAN_PATTERN = "^[A-Z]{2}[0-9]{2}[A-Z0-9]{1,30}";
const MOD_97 = 97;
const COUNTRY_CODE_LENGTH = 2;
const IBAN_CHECK_DIGITS_LENGTH = 4;

final readonly & map<string> chequeCancelStatusCode = {
    "Accepted": "ACCP",
    "Rejected": "RJCR"
};

final readonly & map<string> chequeCancelReasonCode = {
    "DuplicateCheque": "DUPL",
    "RequestedByCustomer": "CUST",
    "FraudulentOrigin": "FRAD",
    "ChequeLost": "LOST",
    "Narrative": "NARR"};

final readonly & map<isolated function> transformFunctionMap =
    {
    "101": transformMT101ToPain001,
    "102": transformMT102ToPcs008,
    "102STP": transformMT102STPToPacs008,
    "103": transformMT103ToPacs008,
    "103STP": transformMT103STPToPacs008,
    "103REMIT": transformMT103REMITToPacs008,
    "107": transformMT107ToPacs003,
    "110": transformMT110ToCamt107,
    "111": transformMT111ToCamt108,
    "112": transformMT112ToCamt109,
    "190": transformMTn90ToCamt105,
    "191": transformMTn91ToCamt106,
    "192": transformMTn92ToCamt055,
    "195": transformMTn95ToCamt026,
    "196": transformMTn96ToCamt029,
    "199": transformMTn99Pacs002,
    "200": transformMT200ToPacs009,
    "201": transformMT201ToPacs009,
    "202": transformMT202Pacs009,
    "202COV": transformMT202COVToPacs009,
    "203": transformMT203ToPacs009,
    "204": transformMT204ToPacs010,
    "205": transformMT205ToPacs009,
    "205COV": transformMT205COVToPacs009,
    "210": transformMT210ToCamt057,
    "290": transformMTn90ToCamt105,
    "291": transformMTn91ToCamt106,
    "292": transformMTn92ToCamt056,
    "295": transformMTn95ToCamt026,
    "296":transformMTn96ToCamt029,
    "299": transformMTn99Pacs002,
    "900": transformMT900ToCamt054,
    "910": transformMT910Camt054,
    "920": transformMT920ToCamt060,
    "940": transformMT940ToCamt053,
    "941": transformMT941ToCamt052,
    "942": transformMT942ToCamt052,
    "950": transformMT950ToCamt053,
    "970": transformMT970ToCamt053,
    "971": transformMT971ToCamt052,
    "972": transformMT972ToCamt052,
    "973": transformMT973ToCamt060,
    "990": transformMTn90ToCamt105,
    "991": transformMTn91ToCamt106,
    "992": transformMTn92ToCamt056,
    "995": transformMTn95ToCamt026,
    "996":transformMTn96ToCamt029
};

const COUNTRY_CODES = ["AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR", "AS", "AT", "AU", "AW", "AX", "AZ",
"BA",  "BB",  "BD",  "BE",  "BF",  "BG",  "BH",  "BI",  "BJ",  "BL",  "BM",  "BN",  "BO",  "BQ",  "BR",  "BS",  "BT", 
"BV",  "BW", "BY", "BZ", "CA", "CC", "CD", "CF", "CG", "CH", "CI", "CK", "CL", "CM", "CN", "CO", "CR", "CU", "CV",
"CW", "CX", "CY", "CZ", "DE", "DJ", "DK", "DM", "DO", "DZ", "EC", "EE", "EG", "EH", "ER", "ES", "ET", "FI", "FJ", "FK",
"FM", "FO", "FR", "GA", "GB", "GD", "GE", "GF", "GG", "GH", "GI", "GL", "GM", "GN", "GP", "GQ", "GR", "GS", "GT", "GU",
"GW", "GY", "HK", "HM", "HN", "HR", "HT", "HU", "ID", "IE", "IL", "IM", "IN", "IO", "IQ", "IR", "IS", "IT", "JE", "JM",
"JO", "JP", "KE", "KG", "KH", "KI", "KM", "KN", "KP", "KR", "KW", "KY", "KZ", "LA", "LB", "LC", "LI", "LK", "LR", "LS",
"LT", "LU", "LV", "LY", "MA", "MC", "MD", "ME", "MF", "MG", "MH", "MK", "ML", "MM", "MN", "MO", "MP", "MQ", "MR", "MS",
"MT", "MU", "MV", "MW", "MX", "MY", "MZ", "NA", "NC", "NE", "NF", "NG", "NI", "NL", "NO", "NP", "NR", "NU", "NZ", "OM",
"PA", "PE", "PF", "PG", "PH", "PK", "PL", "PM", "PN", "PR", "PS", "PT", "PW", "PY", "QA", "RE", "RO", "RS", "RU", "RW",
"SA", "SB", "SD", "SE", "SG", "SH", "SI", "SJ", "SK", "SL", "SM", "SN", "SO", "SR", "SS", "ST", "SV", "SX", "SY", "SZ",
"TC", "TD", "TF", "TG", "TH", "TJ", "TK", "TL", "TM", "TN", "TO", "TR", "TT", "TV", "TW", "TZ", "UA", "UG", "UM", "US",
"UY", "UZ", "VA", "VC", "VE", "VG", "VI", "VN", "VU", "WF", "WS", "XK", "YE", "YT", "ZA", "ZM", "ZW"
];

final readonly & map<string> LETTER_LIST = {"A": "10", "B": "11", "C": "12", "D": "13", "E": "14", "F": "15", "G": "16", "H": "17", "I": "18", "J": "19", "K": "20", "L": "21", "M": "22", "N": "23", "O": "24", "P": "25", "Q": "26", "R": "27", "S": "28", "T": "29", "U": "20", "V": "31", "W": "32", "X": "33", "Y": "34", "Z": "35"};
