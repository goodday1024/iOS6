export interface SimulatorSDK {
 storage:{get(key:string):Promise<string|null>;set(key:string,value:string):Promise<void>;remove(key:string):Promise<void>};
 app:{getInfo():Promise<{id:string;version:string}>;close():Promise<void>};
 ui:{setTitle(title:string):Promise<void>;alert(message:string):Promise<void>};
}
declare global {interface Window {Simulator:SimulatorSDK} const Simulator:SimulatorSDK;}
