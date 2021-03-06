//
// Copyright 2011-2015 Jeff Bush
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//


`include "defines.sv"

//
// Storage for control registers.
//

module control_registers
    #(parameter CORE_ID = 0)
    (input                                  clk,
    input                                   reset,

    // To multiple stages
    output scalar_t                         cr_eret_address[`THREADS_PER_CORE],
    output logic                            cr_mmu_en[`THREADS_PER_CORE],
    output logic                            cr_supervisor_en[`THREADS_PER_CORE],
    output logic[`ASID_WIDTH - 1:0]         cr_current_asid[`THREADS_PER_CORE],

    // From int_execute_stage
    input                                   ix_is_eret,
    input thread_idx_t                      ix_thread_idx,

    // From dcache_data_stage
    // dd_xxx signals are unregistered. dt_thread_idx represents thread going into
    // dcache_data_stage)
    input thread_idx_t                      dt_thread_idx,
    input                                   dd_creg_write_en,
    input                                   dd_creg_read_en,
    input control_register_t                dd_creg_index,
    input scalar_t                          dd_creg_write_val,

    // From writeback_stage
    input                                   wb_trap,
    input trap_reason_t                     wb_trap_reason,
    input scalar_t                          wb_trap_pc,
    input scalar_t                          wb_trap_access_vaddr,
    input thread_idx_t                      wb_trap_thread_idx,
    input subcycle_t                        wb_trap_subcycle,

    // To writeback_stage
    output scalar_t                         cr_creg_read_val,
    output thread_bitmap_t                  cr_interrupt_en,
    output subcycle_t                       cr_eret_subcycle[`THREADS_PER_CORE],
    output scalar_t                         cr_trap_handler,
    output scalar_t                         cr_tlb_miss_handler);

    // We support one level of nested traps, so there are two of
    // each of these trap state arrays.
    scalar_t trap_access_addr[2][`THREADS_PER_CORE];
    trap_reason_t trap_reason[2][`THREADS_PER_CORE];
    scalar_t eret_address[2][`THREADS_PER_CORE];
    logic interrupt_en_saved[2][`THREADS_PER_CORE];
    logic mmu_en_saved[2][`THREADS_PER_CORE];
    logic supervisor_en_saved[2][`THREADS_PER_CORE];
    subcycle_t subcycle_saved[2][`THREADS_PER_CORE];
    scalar_t scratchpad[2][`THREADS_PER_CORE * 2];
    scalar_t page_dir_base[`THREADS_PER_CORE];
    scalar_t cycle_count;

    assign cr_eret_subcycle = subcycle_saved[0];
    assign cr_eret_address = eret_address[0];

    always_ff @(posedge clk, posedge reset)
    begin
        if (reset)
        begin
            for (int thread_idx = 0; thread_idx < `THREADS_PER_CORE; thread_idx++)
            begin
                for (int trap_level = 0; trap_level < 2; trap_level++)
                begin
                    trap_reason[trap_level][thread_idx] <= TR_RESET;
                    trap_access_addr[trap_level][thread_idx] <= '0;
                    subcycle_saved[trap_level][thread_idx] <= '0;
                    interrupt_en_saved[trap_level][thread_idx] <= 0;
                    supervisor_en_saved[trap_level][thread_idx] <= 1;
                    mmu_en_saved[trap_level][thread_idx] <= 0;
                    eret_address[trap_level][thread_idx] <= '0;
                    scratchpad[trap_level][thread_idx] <= '0;
                    scratchpad[trap_level][thread_idx + `THREADS_PER_CORE] <= '0;
                end

                cr_mmu_en[thread_idx] <= 0;
                cr_supervisor_en[thread_idx] <= 1;    // Threads start in supervisor mode
                cr_current_asid[thread_idx] <= '0;
                page_dir_base[thread_idx] <= '0;
            end

            /*AUTORESET*/
            // Beginning of autoreset for uninitialized flops
            cr_interrupt_en <= '0;
            cr_tlb_miss_handler <= '0;
            cr_trap_handler <= '0;
            cycle_count <= '0;
            // End of automatics
        end
        else
        begin
            // Ensure a read and write don't occur in the same cycle
            assert(!(dd_creg_write_en && dd_creg_read_en));

            // A fault and eret are triggered from the same stage, so they
            // must not occur simultaneously (an eret can raise a fault if it
            // is not in supervisor mode, but ix_is_eret should not be asserted
            // in that case)
            assert(!(wb_trap && ix_is_eret));

            cycle_count <= cycle_count + 1;

            if (wb_trap)
            begin
                // For nested traps, copy saved flags into second slot
                trap_access_addr[1][wb_trap_thread_idx] <= trap_access_addr[0][wb_trap_thread_idx];
                trap_reason[1][wb_trap_thread_idx] <= trap_reason[0][wb_trap_thread_idx];
                eret_address[1][wb_trap_thread_idx] <= eret_address[0][wb_trap_thread_idx];
                interrupt_en_saved[1][wb_trap_thread_idx] <= interrupt_en_saved[0][wb_trap_thread_idx];
                mmu_en_saved[1][wb_trap_thread_idx] <= mmu_en_saved[0][wb_trap_thread_idx];
                supervisor_en_saved[1][wb_trap_thread_idx] <= supervisor_en_saved[0][wb_trap_thread_idx];
                subcycle_saved[1][wb_trap_thread_idx] <= subcycle_saved[0][wb_trap_thread_idx];
                scratchpad[1][{1'b0, wb_trap_thread_idx}] <= scratchpad[0][{1'b0, wb_trap_thread_idx}];
                scratchpad[1][{1'b1, wb_trap_thread_idx}] <= scratchpad[0][{1'b1, wb_trap_thread_idx}];

                // Save current flags
                interrupt_en_saved[0][wb_trap_thread_idx] <= cr_interrupt_en[wb_trap_thread_idx];
                mmu_en_saved[0][wb_trap_thread_idx] <= cr_mmu_en[wb_trap_thread_idx];
                supervisor_en_saved[0][wb_trap_thread_idx] <= cr_supervisor_en[ix_thread_idx];
                subcycle_saved[0][wb_trap_thread_idx] <= wb_trap_subcycle;

                // Dispatch fault
                trap_reason[0][wb_trap_thread_idx] <= wb_trap_reason;
                eret_address[0][wb_trap_thread_idx] <= wb_trap_pc;
                trap_access_addr[0][wb_trap_thread_idx] <= wb_trap_access_vaddr;
                cr_interrupt_en[wb_trap_thread_idx] <= 0;    // Disable interrupts for this thread
                cr_supervisor_en[ix_thread_idx] <= 1; // Enter supervisor mode on fault
                if (wb_trap_reason == TR_ITLB_MISS || wb_trap_reason == TR_DTLB_MISS)
                    cr_mmu_en[wb_trap_thread_idx] <= 0;
            end
            else if (ix_is_eret)
            begin
                // Copy from prev flags to current flags
                cr_interrupt_en[ix_thread_idx] <= interrupt_en_saved[0][ix_thread_idx];
                cr_mmu_en[ix_thread_idx] <= mmu_en_saved[0][ix_thread_idx];
                cr_supervisor_en[ix_thread_idx] <= supervisor_en_saved[0][ix_thread_idx];

                // Restore nested interrupt stage
                trap_access_addr[0][ix_thread_idx] <= trap_access_addr[1][ix_thread_idx];
                trap_reason[0][ix_thread_idx] <= trap_reason[1][ix_thread_idx];
                eret_address[0][ix_thread_idx] <= eret_address[1][ix_thread_idx];
                interrupt_en_saved[0][ix_thread_idx] <= interrupt_en_saved[1][ix_thread_idx];
                mmu_en_saved[0][ix_thread_idx] <= mmu_en_saved[1][ix_thread_idx];
                supervisor_en_saved[0][ix_thread_idx] <= supervisor_en_saved[1][ix_thread_idx];
                subcycle_saved[0][ix_thread_idx] <= subcycle_saved[1][ix_thread_idx];
                scratchpad[0][{1'b0, ix_thread_idx}] <= scratchpad[1][{1'b0, ix_thread_idx}];
                scratchpad[0][{1'b1, ix_thread_idx}] <= scratchpad[1][{1'b1, ix_thread_idx}];
            end

            //
            // Write logic
            //
            if (dd_creg_write_en)
            begin
                case (dd_creg_index)
                    CR_FLAGS:
                    begin
                        cr_supervisor_en[dt_thread_idx] <= dd_creg_write_val[2];
                        cr_mmu_en[dt_thread_idx] <= dd_creg_write_val[1];
                        cr_interrupt_en[dt_thread_idx] <= dd_creg_write_val[0];
                    end

                    CR_SAVED_FLAGS:
                    begin
                        supervisor_en_saved[0][dt_thread_idx] <= dd_creg_write_val[2];
                        mmu_en_saved[0][dt_thread_idx] <= dd_creg_write_val[1];
                        interrupt_en_saved[0][dt_thread_idx] <= dd_creg_write_val[0];
                    end

                    CR_TRAP_PC:          eret_address[0][dt_thread_idx] <= dd_creg_write_val;
                    CR_TRAP_HANDLER:     cr_trap_handler <= dd_creg_write_val;
                    CR_TLB_MISS_HANDLER: cr_tlb_miss_handler <= dd_creg_write_val;
                    CR_SCRATCHPAD0:      scratchpad[0][{1'b0, dt_thread_idx}] <= dd_creg_write_val;
                    CR_SCRATCHPAD1:      scratchpad[0][{1'b1, dt_thread_idx}] <= dd_creg_write_val;
                    CR_SUBCYCLE:         subcycle_saved[0][dt_thread_idx] <= subcycle_t'(dd_creg_write_val);
                    CR_CURRENT_ASID:     cr_current_asid[dt_thread_idx] <= dd_creg_write_val[`ASID_WIDTH - 1:0];
                    CR_PAGE_DIR:         page_dir_base[dt_thread_idx] <= dd_creg_write_val;
                    default:
                        ;
                endcase
            end
        end
    end

    always_ff @(posedge clk)
    begin
        //
        // Read logic
        //
        if (dd_creg_read_en)
        begin
            case (dd_creg_index)
                CR_FLAGS:
                begin
                    cr_creg_read_val <= scalar_t'({
                        cr_supervisor_en[dt_thread_idx],
                        cr_mmu_en[dt_thread_idx],
                        cr_interrupt_en[dt_thread_idx]
                    });
                end

                CR_SAVED_FLAGS:
                begin
                    cr_creg_read_val <= scalar_t'({
                        supervisor_en_saved[0][dt_thread_idx],
                        mmu_en_saved[0][dt_thread_idx],
                        interrupt_en_saved[0][dt_thread_idx]
                    });
                end

                CR_THREAD_ID:        cr_creg_read_val <= scalar_t'({CORE_ID, dt_thread_idx});
                CR_TRAP_PC:          cr_creg_read_val <= eret_address[0][dt_thread_idx];
                CR_TRAP_REASON:      cr_creg_read_val <= scalar_t'(trap_reason[0][dt_thread_idx]);
                CR_TRAP_HANDLER:     cr_creg_read_val <= cr_trap_handler;
                CR_TRAP_ADDRESS:     cr_creg_read_val <= trap_access_addr[0][dt_thread_idx];
                CR_TLB_MISS_HANDLER: cr_creg_read_val <= cr_tlb_miss_handler;
                CR_CYCLE_COUNT:      cr_creg_read_val <= cycle_count;
                CR_SCRATCHPAD0:      cr_creg_read_val <= scratchpad[0][{1'b0, dt_thread_idx}];
                CR_SCRATCHPAD1:      cr_creg_read_val <= scratchpad[0][{1'b1, dt_thread_idx}];
                CR_SUBCYCLE:         cr_creg_read_val <= scalar_t'(subcycle_saved[0][dt_thread_idx]);
                CR_CURRENT_ASID:     cr_creg_read_val <= scalar_t'(cr_current_asid[dt_thread_idx]);
                CR_PAGE_DIR:         cr_creg_read_val <= page_dir_base[dt_thread_idx];
                default:             cr_creg_read_val <= 32'hffffffff;
            endcase
        end
    end

endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// verilog-auto-reset-widths:unbased
// End:

