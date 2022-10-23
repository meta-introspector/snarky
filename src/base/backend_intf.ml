open Core_kernel

module type Constraint_system_intf = sig
  module Field : sig
    type t
  end

  type t

  val create : unit -> t

  val finalize : t -> unit

  val add_constraint :
    ?label:string -> t -> (Field.t Cvar.t, Field.t) Constraint.basic -> unit

  val digest : t -> Md5.t

  val set_primary_input_size : t -> int -> unit

  val set_auxiliary_input_size : t -> int -> unit

  val get_rows_len : t -> int
end

module type S = sig
  module Field : Snarky_intf.Field.S

  module Bigint : sig
    module R : Snarky_intf.Bigint_intf.Extended with type field := Field.t
  end

  val field_size : Bigint.R.t

  module Var : sig
    type t

    val index : t -> int

    val create : int -> t
  end

  module R1CS_constraint_system :
    Constraint_system_intf with module Field := Field
end
