module movepixels::pixels {
    use sui::url::{Self, Url};
    // use std::string;
    use sui::object::{Self,ID, UID};
    use sui::event;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::table::{Self,Table};
    use std::option::{Self, Option, some, none,is_some,is_none,borrow_mut,borrow};
    use sui::clock::{Self, Clock};

    struct Global has key {
        id: UID,
        canvas: Option<Canvas>,
        colors: Table<Point, PointInfo>,
        profits: Balance<SUI>, 
        // Every time someone buys a pixel, the price of the remaining pixel goes up 
        priceAdd: u64,
        // The price of the current pixel
        priceForPoint: u64, 
        lastDrawAddress: address,
    }

    struct GlobalCap has key {
        id: UID,
    }


    struct Canvas has store,copy{
        /// The width of the canvas.
        width: u64,
        /// The height of the canvas.
        height: u64,
        /// The duration of the draw. 
        /// becasue of sui::clock::=Clock, use milliseconds
        drawDuration: u64,
        /// The begin time of the canvas. use milliseconds
        begintime: u64,
        /// The lifetime of the canvas. use milliseconds
        lifetime: u64,
    }
   
    
    struct Point has store,drop,copy {
        x: u64,
        y: u64,
    }
    //color is RGBint
    //Blue =  color & 255
    //Green = (color >> 8) & 255
    //Red =   (color>> 16) & 255

    struct PointInfo has store,drop {
        owner: address,
        price: u64,
        color: u64,
        lastDrawTime: u64,
    }

    /// The final canvas NFT struct
    struct ImageNft has key,store {
        id:UID,
        url:Url,
    }

// ===== Events =====
    /// The event emitted when a pixel is drawn.
    struct DrawEvent has copy, drop {
        x: u64,
        y: u64,
        color: u64,
        price: u64,
        owner: address,
    }

    /// The event emitted when the game start.
    struct GameStartEvent has copy, drop {
        objectId: ID,
        width: u64,
        height: u64,
        drawDuration: u64,
        priceForPoint: u64,
        begintime: u64,
        lifetime: u64,
    }

    /// The event emitted when the game end.
    struct GameEndEvent has copy, drop {
        object_id: ID,
        url: Url,
        winner: address,
    }



// ===== Error Constant =====
    const ECanvasExist: u64 = 1000;
    const ECanvasNotExist: u64 = 1001;
    const ECanvasNotStart: u64 = 1002;
    const ECanvasNotEnd: u64 = 1003;
    const ECanvasExpired: u64 = 1004;
    const ECanvasXOutOfBound: u64 = 1005;
    const ECanvasYOutOfBound: u64 = 1006;
    const ECanvasDrawTooFast: u64 = 1007;
    const EProfitsNotEnough: u64 = 1008;
    const ECoinNotEnough: u64 = 1009;
    


// =====  constructor =====

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            GlobalCap {id: object::new(ctx)},
            tx_context::sender(ctx)
        );

        transfer::share_object(
            Global {
                id: object::new(ctx),
                canvas: none(),
                colors: table::new(ctx),
                profits: balance::zero(),
                priceAdd: 0,
                priceForPoint: 0,
                lastDrawAddress: @movepixels,
            }
        );
    }

// ===== Canvas =====
    // Create a new canvas,except begintime
    public entry fun create_canvas(
        width: u64, 
        height: u64, 
        drawDuration: u64, 
        lifetime: u64,
        price: u64,
        priceAdd: u64,
        global: &mut Global,
        _: &mut GlobalCap
    ) {
        assert!(is_none(&global.canvas), ECanvasExist);
        let canvas = Canvas {
            width: width,
            height: height,
            drawDuration: drawDuration,
            begintime: 0,
            lifetime: lifetime,
        };
       
        option::fill(&mut global.canvas, canvas);
        global.priceAdd = priceAdd;
        global.priceForPoint = price;
        

    }

    // Start canvas and add begintime
    public entry fun start_canvas(
        clock: &Clock,
        global: &mut Global,
        _: &mut GlobalCap
    ) {
        assert!(is_some(&global.canvas), ECanvasNotExist);
        let canvas = borrow_mut(&mut global.canvas);
        assert!(canvas.begintime == 0, ECanvasNotStart); 
        let begintime = clock::timestamp_ms(clock);     
        canvas.begintime = begintime;
        event::emit(GameStartEvent {
            objectId: object::uid_to_inner(&global.id),
            width: canvas.width,
            height: canvas.height,
            drawDuration: canvas.drawDuration,
            priceForPoint: global.priceForPoint,
            begintime: canvas.begintime,
            lifetime: canvas.lifetime,
        });
    }

    // End canvas and transfer the canvas nft to the winner
    public entry fun end_canvas(
        clock: &Clock,
        url: vector<u8>,
        global: &mut Global,
        _:&GlobalCap,
        ctx: &mut TxContext
    ) {
        assert!(is_some(&global.canvas), ECanvasNotExist);
        let now = clock::timestamp_ms(clock);
        let canvas = borrow_mut(&mut global.canvas);
        // can't end before lifetime
        assert!(now > canvas.begintime + canvas.lifetime, ECanvasNotEnd);
        let winner = global.lastDrawAddress;   
        let nft = ImageNft {
            id: object::new(ctx),
            url: url::new_unsafe_from_bytes(url),
        };
        transfer::transfer(nft, winner);

        event::emit(GameEndEvent {
            object_id: object::id(global),
            url: url::new_unsafe_from_bytes(url),
            winner: winner,
        });

    }

    // Clear canvas and reset the canvas
    public entry fun clear_canvas(
        clock: &Clock,
        global: &mut Global,
        _: &mut GlobalCap,
    ) {
        assert!(is_some(&global.canvas), ECanvasNotExist);
        // can't clear before the game end
        let now = clock::timestamp_ms(clock);
        let canvas = borrow_mut(&mut global.canvas);
        assert!(now > canvas.begintime + canvas.lifetime, ECanvasNotEnd);

        let canvas = option::extract(&mut global.canvas);
        let Canvas{width: x, height: y, drawDuration: _, begintime: _, lifetime: _} = canvas;
        
        while (x > 0) {
            let x = x - 1;
            while (y > 0) {
                let y = y - 1;
                let point = Point {x: x, y: y};
                if (table::contains(&global.colors, point)) {
                    table::remove(&mut global.colors, point);
                };         
            };
        };
    
        global.priceAdd = 0;
        global.priceForPoint = 0;
        global.lastDrawAddress = @movepixels;
    }

// ===== Points =====
    // Draw a point on the canvas
    public entry fun draw(
        x: u64, 
        y: u64, 
        color: u64, 
        clock: &Clock,
        payment:&mut Coin<SUI>,
        global: &mut Global,
        ctx: &mut TxContext 
    ) {
        assert!(is_some(&global.canvas), ECanvasNotExist);
        assert!(coin::value(payment) >= global.priceForPoint,ECoinNotEnough);
        

        let canvas = borrow(&global.canvas);
        let now = clock::timestamp_ms(clock);
        assert!(now >= canvas.begintime, ECanvasNotStart);
        assert!(now <= canvas.begintime + canvas.lifetime, ECanvasExpired);
        assert!(x < canvas.width, ECanvasXOutOfBound);
        assert!(y < canvas.height, ECanvasYOutOfBound);
        let sender = tx_context::sender(ctx);
        let point = Point {
            x: x,
            y: y,
        };

        if (table::contains(&mut global.colors, point)) {
            let info = table::borrow_mut(&mut global.colors, point);
            assert!(now >= info.lastDrawTime + canvas.drawDuration, ECanvasDrawTooFast);
            info.color = color;
            info.price = global.priceForPoint;
            info.owner = sender;
            info.lastDrawTime = now;
        } else {
            let info = PointInfo {
                color: color,
                price: global.priceForPoint,
                owner: sender,
                lastDrawTime: now,
            };
            table::add(&mut global.colors, point, info);
        };

        let paid = balance::split(coin::balance_mut(payment), global.priceForPoint);
        balance::join(&mut global.profits, paid);

        global.priceForPoint = global.priceForPoint + global.priceAdd;

        event::emit(DrawEvent {
            x: x,
            y: y,
            color: color,
            price: global.priceForPoint,
            owner: sender,
        });
  
    }

// ===== utils =====

// =====  public functions =====

    public fun get_canvas(
        global: &Global
    ): Option<Canvas> {
        if(is_some(&global.canvas)){
            global.canvas
        }else{
            none()
        }
                  
    }

    public fun is_point(
        x: u64,
        y: u64,
        global: &Global
    ): bool {
        let point = Point {
            x: x,
            y: y,
        };
       
        table::contains(&global.colors, point)
    }

    public fun get_point_address(
        x: u64,
        y: u64,
        global: &Global
    ): Option<address> {
        let point = Point {
            x: x,
            y: y,
        };
       
        if (table::contains(&global.colors, point)){
            let info = table::borrow(&global.colors, point);
            some(info.owner)
        }else{
            none()
        }        
    }


    public fun get_price_add(
        global: &Global
    ): u64 {
        global.priceAdd
        
    }

    public fun get_lastDrawAddress(
        global: &mut Global
    ): &address {
        &global.lastDrawAddress
    }

// ===== GlobalCap =====
    public entry fun getProfits(
        global: &mut Global,
        amount: u64,
        _: &mut GlobalCap,
        ctx: &mut TxContext
    ) {
        assert!(amount <= balance::value(&global.profits), EProfitsNotEnough);
        let amount = balance::value(&global.profits);
        let profits = coin::take(&mut global.profits, amount, ctx);

        transfer::transfer(profits, tx_context::sender(ctx))
    }

    public entry fun setPriceAdd(
        priceAdd: u64,
        global: &mut Global,
        _: &mut GlobalCap,
    ) {
        global.priceAdd = priceAdd;
    }

}


