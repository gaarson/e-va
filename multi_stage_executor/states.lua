local M = {}

M.STATES = {
    IDLE              = "IDLE",
    INTENT_DRAFT      = "INTENT_DRAFT",
    INTENT_READY      = "INTENT_READY",
    COMMAND_READY     = "COMMAND_READY",
    REVIEWING         = "REVIEWING",
    APPROVED          = "APPROVED",
    PARTIAL           = "PARTIAL",
    REVISING          = "REVISING",
    COMPLETED         = "COMPLETED",
    ERROR             = "ERROR",
}

return M