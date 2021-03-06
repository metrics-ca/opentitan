// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * OpenTitan Big Number Accelerator (OTBN) Core
 *
 * This module is the top-level of the OTBN processing core.
 */
module otbn_core_model
  import otbn_pkg::*;
#(
  // Size of the instruction memory, in bytes
  parameter int ImemSizeByte = 4096,
  // Size of the data memory, in bytes
  parameter int DmemSizeByte = 4096,

  // Scope of the instruction memory (for DPI)
  parameter string ImemScope = "",
  // Scope of the data memory (for DPI)
  parameter string DmemScope = "",
  // Scope of an RTL OTBN implementation (for DPI). If empty, this is a "standalone" model, which
  // should update DMEM on completion. If not empty, we assume it's the scope for the top-level of a
  // real implementation running alongside and we check DMEM contents on completion.
  parameter string DesignScope = "",

  localparam int ImemAddrWidth = prim_util_pkg::vbits(ImemSizeByte),
  localparam int DmemAddrWidth = prim_util_pkg::vbits(DmemSizeByte)
)(
  input  logic  clk_i,
  input  logic  rst_ni,

  input  logic  start_i, // start the operation
  output logic  done_o,  // operation done

  input  logic [ImemAddrWidth-1:0] start_addr_i, // start byte address in IMEM

  output bit err_o        // something went wrong
);

  import "DPI-C" function chandle otbn_model_init();
  import "DPI-C" function void otbn_model_destroy(chandle handle);
  import "DPI-C" context function
    int unsigned otbn_model_step(chandle      model,
                                 string       imem_scope,
                                 int unsigned imem_size,
                                 string       dmem_scope,
                                 int unsigned dmem_size,
                                 string       design_scope,
                                 logic        start_i,
                                 int unsigned start_addr,
                                 int unsigned status);

  localparam ImemSizeWords = ImemSizeByte / 4;
  localparam DmemSizeWords = DmemSizeByte / (WLEN / 8);

  `ASSERT_INIT(StartAddr32_A, ImemAddrWidth <= 32);
  logic [31:0] start_addr_32;
  assign start_addr_32 = {{32 - ImemAddrWidth{1'b0}}, start_addr_i};

  // Create and destroy an object through which we can talk to the ISS
  chandle model_handle;
  initial begin
    model_handle = otbn_model_init();
    assert(model_handle != 0);
  end
  final begin
    otbn_model_destroy(model_handle);
    model_handle = 0;
  end

  // A packed "status" value. This gets assigned by DPI function calls that need to update both
  // whether we're running and also error flags at the same time. The contents are magic simulation
  // values, so get initialized before reset (to avoid stopping the simulation before it even
  // starts).
  int unsigned status = 0;

  // Extract particular bits of the status value.
  //
  //   running: The ISS is currently running
  //   failed_step: Something went wrong when trying to start or step the ISS.
  //   failed_cmp:  The consistency check at the end of run failed.
  bit failed_cmp, failed_step, running;
  assign {failed_cmp, failed_step, running} = status[2:0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Clear status (stop running, and forget any errors)
      status <= 0;
    end else begin
      if (start_i | running) begin
        status <= otbn_model_step(model_handle,
                                  ImemScope, ImemSizeWords,
                                  DmemScope, DmemSizeWords,
                                  DesignScope,
                                  start_i, start_addr_32,
                                  status);
      end else begin
        // If we're not running and we're not being told to start, there's nothing to do.
      end
    end
  end

  // Track negedges of running_q and expose that as a "done" output.
  bit running_r = 1'b0;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      running_r <= 1'b0;
    end else begin
      running_r <= running;
    end
  end
  assign done_o = running_r & ~running;

  // If DesignScope is not empty, we have a design to check. Bind a copy of otbn_rf_snooper into
  // each register file. The otbn_model_check() function will use these to extract memory contents.
  generate if (DesignScope.len() != 0) begin
    // TODO: This bind is by module, rather than by instance, because I couldn't get the by-instance
    // syntax plus upwards name referencing to work with Verilator. Obviously, this won't work with
    // multiple OTBN instances, so it would be nice to get it right.
    bind otbn_rf_base_ff otbn_rf_snooper #(.Width (32), .Depth (32)) u_snooper (.rf (rf_reg));
    bind otbn_rf_bignum_ff otbn_rf_snooper #(.Width (256), .Depth (32)) u_snooper (.rf (rf));
  end endgenerate

  assign err_o = failed_step | failed_cmp;

endmodule
