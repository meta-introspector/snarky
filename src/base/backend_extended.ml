open Core_kernel
module Bignum_bigint = Bigint

(** Yojson-compatible JSON type. *)
type 'a json =
  [> `String of string
  | `Assoc of (string * 'a json) list
  | `List of 'a json list ]
  as
  'a

module type S = sig
  module Field : Snarky_intf.Field.Full

  module Bigint : sig
    include Snarky_intf.Bigint_intf.Extended with type field := Field.t

    val of_bignum_bigint : Bignum_bigint.t -> t

    val to_bignum_bigint : t -> Bignum_bigint.t
  end

  module Cvar : Backend_intf.Cvar_intf with type field := Field.t

  module Constraint_system :
    Backend_intf.Constraint_system_intf
      with module Field := Field
       and type cvar := Cvar.t

  module Run_state :
    State.S
      with module Field := Field
       and type cvar := Cvar.t
       and type constraint_system := Constraint_system.t

  module Constraint : sig
    type t = (Cvar.t, Field.t) Constraint.t [@@deriving sexp]

    type 'k with_constraint_args = ?label:string -> 'k

    val boolean : (Cvar.t -> t) with_constraint_args

    val equal : (Cvar.t -> Cvar.t -> t) with_constraint_args

    val r1cs : (Cvar.t -> Cvar.t -> Cvar.t -> t) with_constraint_args

    val square : (Cvar.t -> Cvar.t -> t) with_constraint_args

    val annotation : t -> string
  end
end

module Make (Backend : Backend_intf.S) :
  S
    with type Field.t = Backend.Field.t
     and type Cvar.t = Backend.Cvar.t
     and type Field.Vector.t = Backend.Field.Vector.t
     and type Bigint.t = Backend.Bigint.t
     and type Constraint_system.t = Backend.Constraint_system.t = struct
  open Backend

  module Bigint = struct
    include Bigint

    let of_bignum_bigint n = of_decimal_string (Bignum_bigint.to_string n)

    let to_bignum_bigint n =
      let rec go i two_to_the_i acc =
        if i = Field.size_in_bits then acc
        else
          let acc' =
            if test_bit n i then Bignum_bigint.(acc + two_to_the_i) else acc
          in
          go (i + 1) Bignum_bigint.(two_to_the_i + two_to_the_i) acc'
      in
      go 0 Bignum_bigint.one Bignum_bigint.zero
  end

  module Field = struct
    include Field

    let size = Bigint.to_bignum_bigint Backend.field_size

    let inv x = if equal x zero then failwith "Field.inv: zero" else inv x

    (* TODO: Optimize *)
    let div x y = mul x (inv y)

    let negate x = sub zero x

    let unpack x =
      let n = Bigint.of_field x in
      List.init size_in_bits ~f:(fun i -> Bigint.test_bit n i)

    let project_reference =
      let rec go x acc = function
        | [] ->
            acc
        | b :: bs ->
            go (Field.add x x) (if b then Field.add acc x else acc) bs
      in
      fun bs -> go Field.one Field.zero bs

    let _project bs =
      (* todo: 32-bit and ARM support. basically this code needs to always match the loop in the C++ of_data implementation. *)
      assert (Sys.word_size = 64 && not Sys.big_endian) ;
      let chunks_of n xs =
        List.groupi ~break:(fun i _ _ -> Int.equal (i mod n) 0) xs
      in
      let chunks64 = chunks_of 64 bs in
      let z = Char.of_int_exn 0 in
      let arr =
        Bigstring.init (8 * Backend.Bigint.length_in_bytes) ~f:(fun _ -> z)
      in
      List.(
        iteri ~f:(fun i elt ->
            Bigstring.set_int64_t_le arr ~pos:(i * 8)
              Int64.(
                foldi ~init:zero
                  ~f:(fun i acc el ->
                    acc + if el then shift_left one i else zero )
                  elt) ))
        chunks64 ;
      Backend.Bigint.(of_data arr ~bitcount:(List.length bs) |> to_field)

    let project = project_reference

    let compare t1 t2 = Bigint.(compare (of_field t1) (of_field t2))

    let hash_fold_t s x =
      Bignum_bigint.hash_fold_t s Bigint.(to_bignum_bigint (of_field x))

    let hash = Hash.of_fold hash_fold_t

    let to_bignum_bigint = Fn.compose Bigint.to_bignum_bigint Bigint.of_field

    let of_bignum_bigint = Fn.compose Bigint.to_field Bigint.of_bignum_bigint

    let sexp_of_t = Fn.compose Bignum_bigint.sexp_of_t to_bignum_bigint

    let t_of_sexp = Fn.compose of_bignum_bigint Bignum_bigint.t_of_sexp

    let to_string = Fn.compose Bignum_bigint.to_string to_bignum_bigint

    let of_string = Fn.compose of_bignum_bigint Bignum_bigint.of_string

    let%test_unit "project correctness" =
      Quickcheck.test
        Quickcheck.Generator.(
          small_positive_int >>= fun x -> list_with_length x bool)
        ~f:(fun bs ->
          [%test_eq: string]
            (project bs |> to_string)
            (project_reference bs |> to_string) )

    let ( + ) = add

    let ( * ) = mul

    let ( - ) = sub

    let ( / ) = div
  end

  module Cvar = Cvar
  module Constraint_system = Constraint_system
  module Run_state = State.Make (Cvar) (Field) (Constraint_system) (Run_state)

  module Constraint = struct
    include Constraint.T

    type 'k with_constraint_args = ?label:string -> 'k

    type t = (Cvar.t, Field.t) Constraint.t

    let t_of_sexp _ = failwith "unimplemented"

    let sexp_of_t = sexp_of_opaque
  end
end
