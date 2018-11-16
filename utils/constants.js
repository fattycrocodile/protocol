import BN from "bn.js"

export const constants = {
    NULL_ADDRESS: "0x0000000000000000000000000000000000000000",
    NULL_BYTES: "0x0000000000000000000000000000000000000000000000000000000000000000",
    TOKEN_UNIT: (new BN(10)).pow(new BN(18)),
    PERC_DIVISOR: 1000000,
    PERC_MULTIPLIER: 10000,
    DelegatorStatus: {
        Pending: 0,
        Bonded: 1,
        Unbonded: 2
    },
    TranscoderStatus: {
        NotRegistered: 0,
        Registered: 1
    }
}
