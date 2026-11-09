`ifndef AXI_UTILS_SV
`define AXI_UTILS_SV

// =============================================================================
// axi_utils.sv  (included inside axi_tb_pkg)
//   Common types and helper functions used by drivers, monitors and the
//   reference model. Address/strobe math lives here ONCE so every component
//   agrees on it.
// =============================================================================

typedef enum bit {AXI_WRITE = 1'b0, AXI_READ = 1'b1} axi_kind_e;

// -----------------------------------------------------------------------------
// Address of beat n of a burst (AXI4 spec A3.4.1)
// -----------------------------------------------------------------------------
function automatic bit [AXI_AW-1:0] axi_beat_addr(bit [AXI_AW-1:0] addr,
                                                  bit [2:0]        size,
                                                  bit [7:0]        len,
                                                  bit [1:0]        burst,
                                                  int unsigned     n);
  bit [AXI_AW-1:0] nbytes, aligned, total, lower, a;
  nbytes  = 32'd1 << size;
  aligned = (addr / nbytes) * nbytes;
  if (burst == BURST_FIXED) begin
    return addr;
  end
  else if (burst == BURST_WRAP) begin
    total = nbytes * ({24'd0, len} + 32'd1);
    lower = (addr / total) * total;
    a     = aligned + n * nbytes;
    if (a >= lower + total) a = a - total;
    return a;
  end
  else begin // INCR (and reserved 2'b11 treated as INCR)
    return (n == 0) ? addr : aligned + n * nbytes;
  end
endfunction

// -----------------------------------------------------------------------------
// Byte lanes that are valid for a beat at address baddr with size "size"
// -----------------------------------------------------------------------------
function automatic bit [AXI_SW-1:0] axi_lane_mask(bit [AXI_AW-1:0] baddr, bit [2:0] size);
  int unsigned nbytes, lo, hi;
  bit [AXI_SW-1:0] m;
  nbytes = 1 << size;
  lo     = baddr % AXI_SW;
  hi     = ((baddr / nbytes) * nbytes) % AXI_SW + nbytes - 1;
  m      = '0;
  for (int unsigned b = 0; b < AXI_SW; b++)
    if (b >= lo && b <= hi) m[b] = 1'b1;
  return m;
endfunction

// Byte address of lane "lane" inside the bus word that contains baddr
function automatic bit [AXI_AW-1:0] axi_lane_addr(bit [AXI_AW-1:0] baddr, int unsigned lane);
  return (baddr / AXI_SW) * AXI_SW + lane;
endfunction

// Random "pct percent of the time" helper (pct = 0 -> never, 100 -> always)
function automatic bit axi_chance(int unsigned pct);
  if (pct == 0) return 1'b0;
  return ($urandom_range(99) < pct);
endfunction

function automatic string axi_resp_str(bit [1:0] r);
  case (r)
    RESP_OKAY:   return "OKAY";
    RESP_EXOKAY: return "EXOKAY";
    RESP_SLVERR: return "SLVERR";
    default:     return "DECERR";
  endcase
endfunction

function automatic string axi_burst_str(bit [1:0] b);
  case (b)
    BURST_FIXED: return "FIXED";
    BURST_INCR:  return "INCR";
    BURST_WRAP:  return "WRAP";
    default:     return "RSVD";
  endcase
endfunction
`endif // AXI_UTILS_SV
