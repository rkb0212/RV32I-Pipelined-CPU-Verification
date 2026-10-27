// =============================================================================
// lsu.sv
// Used in: MEM stage, between the EX/MEM pipeline register and data_memory.sv
//   (L1).
// How it works: drives the address/data/enables data_memory.sv (or, once
//   spliced in, l2_cache.sv) expects, then muxes the final MEM-stage result:
//   a load takes the fetched word, anything else passes the ALU result
//   straight through untouched. mem_stall exists for interface completeness
//   (a multi-cycle L2/L3/iMC miss would assert it) but is always 0 today
//   since data_memory.sv's req_ready/resp_valid are hardwired to 1.
// Why it's used: this is the "LSU" block in the diagram, and the only block
//   that talks to the memory hierarchy below it.
// =============================================================================
module lsu #(
  parameter int DATA_W = 32
)(
  // EX/MEM pipeline register
  input  logic [DATA_W-1:0] ex_mem_alu_result,   // effective address
  input  logic [DATA_W-1:0] ex_mem_store_data,
  input  logic               ex_mem_mem_write,
  input  logic               ex_mem_mem_to_reg,

  // data_memory.sv (L1) port
  output logic [DATA_W-1:0] cache_addr,
  output logic [DATA_W-1:0] cache_wdata,
  output logic               cache_wr_en,
  output logic               cache_rd_en,
  input  logic [DATA_W-1:0] cache_rdata,
  input  logic               cache_req_ready,
  input  logic               cache_resp_valid,
  input  logic               cache_misaligned,
  input  logic               cache_out_of_range,

  output logic [DATA_W-1:0] mem_result,
  output logic               mem_stall,
  output logic               mem_misaligned,
  output logic               mem_out_of_range
);

  wire access = ex_mem_mem_write || ex_mem_mem_to_reg;

  assign cache_addr  = ex_mem_alu_result;
  assign cache_wdata = ex_mem_store_data;
  assign cache_wr_en = ex_mem_mem_write;
  assign cache_rd_en = ex_mem_mem_to_reg;

  assign mem_result = ex_mem_mem_to_reg ? cache_rdata : ex_mem_alu_result;

  // Would stall the pipeline on a multi-cycle miss; always 0 against
  // today's single-cycle data_memory.sv.
  assign mem_stall = access && (!cache_req_ready || !cache_resp_valid);

  assign mem_misaligned   = access && cache_misaligned;
  assign mem_out_of_range = access && cache_out_of_range;

endmodule
